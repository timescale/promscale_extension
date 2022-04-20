use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::vec::Vec;
use testcontainers::clients::Cli;
use testcontainers::images::generic::{GenericImage, WaitFor};
use testcontainers::{clients, Container};
use testcontainers::{images, Docker};

/// A docker container running Postgres
type PostgresContainer<'d> = Container<'d, Cli, GenericImage>;

/// Returns the name of the docker image to use for Postgres containers.
/// If the `TS_DOCKER_IMAGE` environment variable is set, it will return that value.
/// Otherwise, it returns a default image.
fn postgres_image() -> String {
    env::var("TS_DOCKER_IMAGE").unwrap_or_else(|_| {
        String::from("ghcr.io/timescale/dev_promscale_extension:develop-ts2-pg14")
    })
}

/// Creates and runs a docker container running Postgres
fn run_postgres<'a>(
    docker: &'a Cli,
    docker_image: &str,
    db: &str,
    username: &str,
    volumes: Option<&Vec<(&str, &str)>>,
) -> PostgresContainer<'a> {
    let mut generic_postgres = images::generic::GenericImage::new(docker_image)
        .with_wait_for(WaitFor::message_on_stderr(
            "database system is ready to accept connections",
        ))
        .with_env_var("POSTGRES_DB", db)
        .with_env_var("POSTGRES_USER", username)
        .with_env_var("POSTGRES_HOST_AUTH_METHOD", "trust")
        .with_env_var("POSTGRES_PASSWORD", "password");

    if let Some(volumes) = volumes {
        for volume in volumes.iter() {
            generic_postgres = generic_postgres.with_volume(volume.0, volume.1);
        }
    }

    docker.run(generic_postgres)
}

/// Runs a SQL script file in the docker container
///
/// The script file is copied into the container, and executed with
/// psql using the `-f` flag.
///
/// # Arguments
///
/// * `container` - the docker container running postgres in which to run the sql command
/// * `db` - the database to connect psql to with the `-d` flag
/// * `username` - the username to be used on the psql connection with the `-U` flag
/// * `path` - the path to the sql script on the host to execute using the `-f` flag
///
fn psql_file(container: &PostgresContainer, db: &str, username: &str, path: &Path) {
    println!("executing psql script {}...", path.display());
    let exit = Command::new("docker")
        .arg("exec")
        .arg(container.id())
        .arg("psql")
        .args(["-U", username])
        .args(["-d", db])
        .arg("--no-password")
        .arg("--no-psqlrc")
        .arg("--no-readline")
        .arg("--echo-all")
        .args(["-v", "ON_ERROR_STOP=1"])
        .args(["-f", path.to_str().unwrap()])
        .spawn()
        .unwrap()
        .wait()
        .unwrap();
    assert!(
        exit.success(),
        "executing psql script {} failed: {}",
        path.display(),
        exit
    );
}

/// Runs a SQL script in the docker container
///
/// The script is saved to a temp file, copied into the container, and executed with
/// psql using the `-f` flag.
///
/// # Arguments
///
/// * `container` - the docker container running postgres in which to run the sql command
/// * `db` - the database to connect psql to with the `-d` flag
/// * `username` - the username to be used on the psql connection with the `-U` flag
/// * `script` - the sql script to execute using the `-f` flag
///
fn psql_script(container: &PostgresContainer, db: &str, username: &str, script: &str) {
    let src = env::temp_dir().join("psql-stmts.sql");
    if src.exists() {
        fs::remove_file(src.clone()).expect("failed to remove existing script file");
    }
    fs::write(&src, script).expect("failed to write statements to temp script file");
    let dest = PathBuf::from("/tmp/script.sql");
    copy_in(container, &src, &dest);
    psql_file(container, db, username, &dest);
}

/// Runs a SQL command in the docker container
///
/// # Arguments
///
/// * `container` - the docker container running postgres in which to run the sql command
/// * `db` - the database to connect psql to with the `-d` flag
/// * `username` - the username to be used on the psql connection with the `-U` flag
/// * `cmd` - the sql command to execute using the `-c` flag
fn psql_cmd(container: &PostgresContainer, db: &str, username: &str, cmd: &str) {
    println!("executing psql command: {}", cmd);
    let exit = Command::new("docker")
        .arg("exec")
        .arg(container.id())
        .arg("psql")
        .args(["-U", username])
        .args(["-d", db])
        .arg("--no-password")
        .arg("--no-psqlrc")
        .arg("--no-readline")
        .arg("--echo-all")
        .args(["-v", "ON_ERROR_STOP=1"])
        .args(["-c", cmd])
        .spawn()
        .unwrap()
        .wait()
        .unwrap();
    assert!(exit.success(), "psql command '{}' failed: {}", cmd, exit);
}

/// Copies a file from the host into the docker container
///
/// # Arguments
///
/// * `container` - the docker container
/// * `src` - the path to the file on the host to copy
/// * `dest` - the path on the container to copy the file to
///
fn copy_in(container: &Container<Cli, GenericImage>, src: &Path, dest: &Path) {
    let exit = Command::new("docker")
        .arg("cp")
        .arg(src.to_str().unwrap())
        .arg(format!("{}:{}", container.id(), dest.display()))
        .spawn()
        .unwrap()
        .wait()
        .unwrap();
    assert!(
        exit.success(),
        "copying the file into the container failed: {}",
        exit
    );
}

/// Copies a file from the docker container to the host
///
/// # Arguments
///
/// * `container` - the docker container
/// * `src` - the path to the file in the container to copy
/// * `dest` - the path on the host to copy the file to
///
fn copy_out(container: &Container<Cli, GenericImage>, src: &Path, dest: &Path) {
    if dest.exists() {
        fs::remove_file(dest).expect("failed to remove existing dest file");
    }
    let exit = Command::new("docker")
        .arg("cp")
        .arg(format!("{}:{}", container.id(), src.display()))
        .arg(dest.to_str().unwrap())
        .spawn()
        .unwrap()
        .wait()
        .unwrap();
    assert!(
        exit.success(),
        "copying the file out of the container failed: {}",
        exit
    );
}

/// Captures a "snapshot" of a database's state
///
/// Executes the script at e2e/scripts/snapshot.sql against the database in the container,
/// saves the results to a file and returns the contents of the file. The script runs a number
/// of queries to capture the state of both the database's structure and data.
///
/// # Arguments
///
/// * `container` - the docker container running postgres
/// * `db` - the database to snapshot
/// * `username` - the user to connect to the database with
/// * `path` - the path to a file on the host where the snapshot should be saved
///
/// # Returns
///
/// Returns the contents of the snapshot
///
fn snapshot_db(container: &PostgresContainer, db: &str, username: &str, path: &Path) -> String {
    println!("snapshotting database {} via {} user...", db, username);
    let exit = Command::new("docker")
        .arg("exec")
        .arg(container.id())
        .arg("psql")
        .args(["-U", username])
        .args(["-d", db])
        .arg("--no-password")
        .arg("--no-psqlrc")
        .arg("--no-readline")
        .arg("--echo-all")
        .args(["-o", "/tmp/snapshot.txt"])
        .args(["-f", "/scripts/snapshot.sql"])
        .spawn()
        .unwrap()
        .wait()
        .unwrap();
    assert!(
        exit.success(),
        "snapshotting the database {} via {} user failed: {}",
        db,
        username,
        exit
    );
    let src = PathBuf::from("/tmp/snapshot.txt");
    copy_out(container, &src, path);
    fs::read_to_string(path).unwrap()
}

/// Uses pg_dump to create a logical backup
///
/// # Arguments
///
/// * `container` - the docker container running postgres
/// * `db` - the database to backup
/// * `username` - the user to run the backup
/// * `path` - path to the file on the host where the backup should be saved
///
fn dump_db(container: &PostgresContainer, db: &str, username: &str, path: &Path) {
    let dump = Path::new("/tmp/dump.sql");
    let exit = Command::new("docker")
        .arg("exec")
        .arg(container.id())
        .arg("pg_dump")
        .args(["-U", username])
        .args(["-d", db])
        .arg("-v")
        .args(["-F", "p"])
        .args(["-f", dump.to_str().unwrap()])
        .spawn()
        .unwrap()
        .wait()
        .unwrap();
    assert!(
        exit.success(),
        "dumping the database {} via {} user failed: {}",
        db,
        username,
        exit
    );
    copy_out(container, dump, path);
}

/// Restores a database from a logical backup generated by `pg_dump -F p`
///
/// # Arguments
///
/// * `container` - the docker container running postgres
/// * `db` - the database to connect psql to with the `-d` flag to run the restore against
/// * `username` - the user to run the restore script
/// * `path` - the path on the host to the dump file
///
fn restore_db(container: &PostgresContainer, db: &str, username: &str, path: &Path) {
    let dump = Path::new("/tmp/dump.sql");
    copy_in(container, path, dump);
    psql_file(container, db, username, dump);
}

/// Tests the process of dumping and restoring a database using pg_dump
///
/// 1. create a postgres docker container
/// 2. create metrics, series, samples, exemplars, traces in the database
/// 3. snapshot the database
/// 4. use pg_dump to create a logical sql dump
/// 5. destroy the docker container and create a new one
/// 6. restore into the new database
/// 7. snapshot the database
/// 8. compare the two snapshots. they should be equal
#[test]
fn dump_restore_test() {
    // create a temp dir to use for the test
    let dir = &env::temp_dir().join("promscale-dump-restore-test");
    if dir.exists() {
        fs::remove_dir_all(dir).expect("failed to remove temp dir");
    }
    fs::create_dir_all(dir).expect("failed to create temp dir");
    let dump = dir.join("dump.sql");

    println!("temp test files in {}", dir.display());

    let docker = clients::Cli::default();
    let postgres_image = postgres_image();
    // mount the <project>/e2e/scripts directory to the /scripts path in the container
    let volumes = vec![(concat!(env!("CARGO_MANIFEST_DIR"), "/scripts"), "/scripts")];

    // create the first container, load it with data, snapshot it, and dump it
    let container = run_postgres(
        &docker,
        postgres_image.as_str(),
        "db",
        "postgres",
        Some(&volumes),
    );
    psql_file(&container, "db", "postgres", Path::new("/scripts/init.sql"));
    psql_script(
        &container,
        "db",
        "postgres",
        r#"
create user bob;
grant prom_admin, postgres to bob;"#, // todo: bob should not need postgres role
    );
    let snapshot0 = snapshot_db(&container, "db", "bob", &dir.join("snapshot0.txt"));
    dump_db(&container, "db", "postgres", &dump); // todo: dump using bob user
    container.stop();
    container.rm();

    // create the second container, restore into it, snapshot it
    let container = run_postgres(
        &docker,
        postgres_image.as_str(),
        "db",
        "postgres",
        Some(&volumes),
    );
    psql_script(
        &container,
        "db",
        "postgres",
        r#"
create user bob;
grant all on database db to bob;
grant postgres to bob;"#, // todo: bob should not need postgres role
    );
    psql_script(
        &container,
        "db",
        "postgres", // todo: use bob for this
        r#"
create extension if not exists timescaledb;
select public.timescaledb_pre_restore();
create extension if not exists promscale;"#,
    );
    restore_db(&container, "db", "postgres", &dump);
    psql_script(
        &container,
        "db",
        "postgres", // todo: use bob for this
        r#"
select public.timescaledb_post_restore();
select public.promscale_post_restore();"#,
    );
    psql_cmd(&container, "db", "postgres", "grant prom_admin to bob;");
    let snapshot1 = snapshot_db(&container, "db", "bob", &dir.join("snapshot1.txt"));
    container.stop();
    container.rm();

    // don't do `assert_eq!(snapshot0, snapshot1);`
    // it prints both entire snapshots and is impossible to read
    let are_snapshots_equal = snapshot0 == snapshot1;
    assert!(are_snapshots_equal);
}
