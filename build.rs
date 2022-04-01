use crate::SqlType::{Idempotent, Migration};
use askama::Template;
use std::fs::File;
use std::io::{Error, Read, Write};
use std::path::{Path, PathBuf};
use std::string::String;
use std::{env, fs};

#[derive(Template)]
#[template(path = "migration-wrapper.sql", escape = "none")]
struct MigrationWrapper<'a> {
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

fn main() {
    println!("cargo:rerun-if-changed=Cargo.lock");
    // Note: directories are not traversed, instead Cargo looks at the mtime of the directory.
    println!("cargo:rerun-if-changed=migration");
    println!("cargo:rerun-if-changed=migration/migration");
    println!("cargo:rerun-if-changed=migration/idempotent");
    println!("cargo:rerun-if-changed=templates");
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

/// This procedure reads the SQL files placed in the `migration/{idempotent,migration}`
/// directories, wraps each file in its respective template (in the `templates` directory), and
/// outputs the whole contents as one long SQL file (`MIGRATION_FILE_NAME`) in the root directory.
fn generate_migration_sql(manifest_dir: &str) {
    let mut sql = include_str!("migration/migration-table.sql").to_string();
    let rendered_sql = render_sql().expect("unable to render migrations");
    sql.push_str(rendered_sql.as_str());

    let mut out_path = PathBuf::from(manifest_dir);
    out_path.push(MIGRATION_FILE_NAME);
    let mut file = File::create(out_path).unwrap();
    file.write_all(sql.as_bytes())
        .expect("unable to write migration file contents");
}

fn render_sql() -> Result<String, Error> {
    let mut migration_dir = env::current_dir()?;
    migration_dir.push("migration");
    let mut result = String::new();
    for sql_type in &[Migration, Idempotent] {
        let mut path = migration_dir.clone();
        path.push(dir_for_type(sql_type));
        result += render_file(path, sql_type)?.as_str();
    }
    Ok(result)
}

fn dir_for_type(sql_type: &SqlType) -> String {
    match sql_type {
        Migration => "migration".to_string(),
        Idempotent => "idempotent".to_string(),
    }
}

fn render_file(path: PathBuf, sql_type: &SqlType) -> Result<String, Error> {
    let mut result = String::new();
    let mut paths: Vec<PathBuf> = fs::read_dir(path)?.map(|f| f.unwrap().path()).collect();
    paths.sort();
    paths.into_iter().for_each(|path| {
        result += wrap(&path, sql_type).as_str();
    });
    Ok(result)
}

#[derive(Copy, Clone, Debug)]
enum SqlType {
    Migration,
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
        SqlType::Migration => wrap_migration_file(filename, version, &body),
        SqlType::Idempotent => wrap_idempotent_file(filename, version, &body),
    }
}

fn wrap_idempotent_file(filename: &str, _version: &str, body: &str) -> String {
    let idempotent_wrapper = IdempotentWrapper { filename, body };
    idempotent_wrapper
        .render()
        .expect("unable to render template")
}

fn wrap_migration_file(filename: &str, version: &str, body: &str) -> String {
    let migration_wrapper = MigrationWrapper {
        filename,
        version,
        body,
    };
    migration_wrapper
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
