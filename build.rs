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
    body: String,
}

#[derive(Template)]
#[template(path = "idempotent-wrapper.sql", escape = "none")]
struct IdempotentWrapper<'a> {
    filename: &'a str,
    body: String,
}

const MIGRATION_FILE_NAME: &str = "hand-written-migration.sql";

/// This build script reads the SQL files placed in the `migration/{idempotent,migration}`
/// directories, wraps each file in its respective template (in the `templates` directory), and
/// outputs the whole contents as one long SQL file (`MIGRATION_FILE_NAME`) in the root directory.
fn main() {
    println!("cargo:rerun-if-changed=Cargo.lock");
    // Note: directories are not traversed, instead Cargo looks at the mtime of the directory.
    println!("cargo:rerun-if-changed=migration");
    println!("cargo:rerun-if-changed=migration/migration");
    println!("cargo:rerun-if-changed=migration/idempotent");
    println!("cargo:rerun-if-changed=templates");

    let mut sql = include_str!("migration/migration-table.sql").to_string();
    let rendered_sql = render_sql().expect("unable to render migrations");
    sql.push_str(rendered_sql.as_str());

    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let mut out_path = PathBuf::from(manifest_dir);
    out_path.push(MIGRATION_FILE_NAME);
    let mut file = File::create(out_path).unwrap();
    file.write_all(sql.as_bytes())
        .expect("unable to write file contents");
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
        SqlType::Migration => wrap_migration_file(filename, version, body),
        SqlType::Idempotent => wrap_idempotent_file(filename, version, body),
    }
}

fn wrap_idempotent_file(filename: &str, _version: &str, body: String) -> String {
    let idempotent_wrapper = IdempotentWrapper { filename, body };
    idempotent_wrapper
        .render()
        .expect("unable to render template")
}

fn wrap_migration_file(filename: &str, version: &str, body: String) -> String {
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
