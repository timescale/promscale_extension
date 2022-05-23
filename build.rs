use crate::SqlType::{Idempotent, Incremental};
use askama::Template;
use std::fs::File;
use std::io::{Error, Read, Write};
use std::path::{Path, PathBuf};
use std::string::String;
use std::{env, fs};

#[derive(Template)]
#[template(path = "incremental-wrapper.sql", escape = "none")]
struct IncrementalWrapper<'a> {
    filename: &'a str,
    version: &'a str,
    body: &'a str,
}

#[derive(Template)]
#[template(path = "idempotent-wrapper.sql", escape = "none")]
struct IdempotentWrapper<'a> {
    filename: &'a str,
    body: &'a str,
}

#[derive(Template)]
#[template(path = "promscale.control", escape = "none")]
struct ControlFile {
    is_pg_12: bool,
}

const CONTROL_FILE_NAME: &str = "promscale.control";
const MIGRATION_FILE_NAME: &str = "hand-written-migration.sql";
const BOOTSTRAP_FILE_NAME: &str = "bootstrap.sql";

fn main() {
    println!("cargo:rerun-if-changed=Cargo.lock");
    // Note: directories are not traversed, instead Cargo looks at the mtime of the directory.
    println!("cargo:rerun-if-changed=migration");
    println!("cargo:rerun-if-changed=migration/incremental");
    println!("cargo:rerun-if-changed=migration/idempotent");
    println!("cargo:rerun-if-changed=templates");
    println!("cargo:rerun-if-changed=migration/bootstrap");
    // According to the cargo documentation we are horribly misusing
    // the build script mechanism, hence this workaround:
    // "Build scripts may save any output files or intermediate artifacts
    // in the directory specified in the OUT_DIR environment variable.
    // Scripts should not modify any files outside of that directory."
    //
    // Forces build.rs to run every time and generate control file anew.
    // Otherwise it runs only once per feature combination, making it
    // difficult to switch back and forth between PG versions.
    // We should remove this as soon as we drop PG 12 support.
    println!("cargo:rerun-if-changed={}", CONTROL_FILE_NAME);

    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    generate_migration_sql(manifest_dir.as_str());
    generate_control_file(manifest_dir.as_str());
}

/// This procedure generates promscale.control file based on postgresql version.
/// Specifically, PostgreSQL 12 doesn't support 'trusted' extension functionality.
fn generate_control_file(manifest_dir: &str) {
    let features: std::collections::HashSet<String> = env::vars()
        .filter(|(k, _)| k.starts_with("CARGO_FEATURE_"))
        .map(|(k, _)| k.replace("CARGO_FEATURE_", "").to_ascii_lowercase())
        .collect();
    let is_pg_12 = features.contains(&"pg12".to_string());
    let control_file_contents = ControlFile { is_pg_12 }.render().unwrap();

    let mut control_file_path = PathBuf::from(manifest_dir);
    control_file_path.push(CONTROL_FILE_NAME);
    let mut control_file = File::create(control_file_path).unwrap();
    control_file
        .write_all(control_file_contents.as_bytes())
        .expect("unable to write control file contents");
}

/// This procedure reads the SQL files placed in the `migration/{idempotent,incremental}`
/// directories, wraps each file in its respective template (in the `templates` directory), and
/// outputs the whole contents as one long SQL file (`MIGRATION_FILE_NAME`) in the root directory.
fn generate_migration_sql(manifest_dir: &str) {
    let rendered_sql = render_sql().expect("unable to render migrations");

    let mut out_path = PathBuf::from(manifest_dir);
    out_path.push(MIGRATION_FILE_NAME);
    let mut file = File::create(out_path).unwrap();
    file.write_all(rendered_sql.as_bytes())
        .expect("unable to write file contents");

    let mut bootstrap_out_path = PathBuf::from(manifest_dir);
    bootstrap_out_path.push(BOOTSTRAP_FILE_NAME);
    let mut bootstrap_out_file = File::create(bootstrap_out_path).unwrap();
    bootstrap_out_file
        .write_all(render_bootstrap(manifest_dir).as_bytes())
        .expect("unable to write file contents")
}

fn render_bootstrap(manifest_dir: &str) -> String {
    let migration_table_sql =
        include_str!("migration/bootstrap/000-migration-table.sql").to_string();

    let mut ext_schema_path = PathBuf::from(manifest_dir);
    ext_schema_path.push("migration/bootstrap/001-create-ext-schema.sql");
    let ext_schema_sql = wrap(ext_schema_path.as_path(), &Incremental);

    let stop_bgw_sql = include_str!("migration/bootstrap/002-stop-bgw.sql").to_string();

    let mut result = String::from("");
    result.push_str(&migration_table_sql);
    result.push_str(&ext_schema_sql);
    result.push_str(&stop_bgw_sql);
    result
}

fn render_sql() -> Result<String, Error> {
    let mut migration_dir = env::current_dir()?;
    migration_dir.push("migration");
    let mut result = String::new();
    for sql_type in &[Incremental, Idempotent] {
        let mut path = migration_dir.clone();
        path.push(dir_for_type(sql_type));
        result += render_file(path, sql_type)?.as_str();
    }
    Ok(result)
}

fn dir_for_type(sql_type: &SqlType) -> String {
    match sql_type {
        Incremental => "incremental".to_string(),
        Idempotent => "idempotent".to_string(),
    }
}

fn render_file(path: PathBuf, sql_type: &SqlType) -> Result<String, Error> {
    let sql_type_str = match sql_type {
        SqlType::Incremental => "incremental",
        SqlType::Idempotent => "idempotent",
    };
    let mut result = String::new();
    let mut paths: Vec<PathBuf> = fs::read_dir(path)?.map(|f| f.unwrap().path()).collect();
    paths.sort();
    let mut prev = 0;
    paths.into_iter().for_each(|path| {
        let curr = numeric_prefix(&path);
        // 999 prefix is special for a single script we want to always be last in idempotent
        if matches!(sql_type, SqlType::Incremental)
            || (matches!(sql_type, SqlType::Idempotent) && curr != 999)
        {
            // assert that the numeric prefixes are in order with no gaps or duplicates
            assert_eq!(
                curr,
                prev + 1,
                "there must be no gaps nor duplicates in the ordering of {} files: {}",
                sql_type_str,
                path.to_str().unwrap()
            );
        }
        if matches!(sql_type, SqlType::Idempotent) {
            assert_ne!(curr, 1000, "no scripts allowed with prefix > 999");
        }
        prev = curr;
        result += wrap(&path, sql_type).as_str();
    });
    Ok(result)
}

/// Parses and returns the numeric prefix in the filename of each idempotent and incremental file
fn numeric_prefix(path: &Path) -> i32 {
    let file_name = path.file_name().unwrap().to_str().unwrap();
    let (prefix, _) = file_name
        .split_once('-')
        .expect("failed to split filename on dash delimiter");
    prefix
        .parse()
        .expect("failed to parse numeric prefix from filename")
}

#[derive(Copy, Clone, Debug)]
enum SqlType {
    Incremental,
    Idempotent,
}

fn wrap(path: &Path, sql_type: &SqlType) -> String {
    let filename = path
        .file_name()
        .expect("invalid path")
        .to_str()
        .expect("unable to convert file path to str");
    let version = env!("CARGO_PKG_VERSION");
    let body = read_file(path);
    match sql_type {
        SqlType::Incremental => wrap_incremental_file(filename, version, &body),
        SqlType::Idempotent => wrap_idempotent_file(filename, version, &body),
    }
}

fn wrap_idempotent_file(filename: &str, _version: &str, body: &str) -> String {
    let idempotent_wrapper = IdempotentWrapper { filename, body };
    idempotent_wrapper
        .render()
        .expect("unable to render template")
}

fn wrap_incremental_file(filename: &str, version: &str, body: &str) -> String {
    let incremental_wrapper = IncrementalWrapper {
        filename,
        version,
        body,
    };
    incremental_wrapper
        .render()
        .expect("unable to render template")
}

fn read_file(path: &Path) -> String {
    let mut contents = String::new();
    let mut file = File::open(path).expect("unable to open file");
    file.read_to_string(&mut contents)
        .expect("unable to read file");
    contents
}
