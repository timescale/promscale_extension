use regex::Regex;
use similar::{ChangeTag, TextDiff};
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
/// Executes a script file in the container with psql using the `-f` flag.
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
#[allow(dead_code)]
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
#[allow(dead_code)]
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
#[allow(dead_code)]
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

/// Edits a snapshot file to account for acceptable differences
fn normalize_snapshot(path: &Path) -> String {
    let snapshot = fs::read_to_string(path).expect("failed to read snapshot file");

    // partition constraints are printed with the OID of the table, but OIDs are allowed to change
    let re = Regex::new(r"Partition constraint: satisfies_hash_partition\('\d+'::oid").unwrap();
    let snapshot = re.replace_all(
        &snapshot,
        "Partition constraint: satisfies_hash_partition('*'::oid",
    );

    fs::write(path, snapshot.as_bytes()).expect("failed to write snapshot file");
    snapshot.to_string()
}

/// Captures a "snapshot" of a database's state
///
/// Executes the script at e2e/scripts/snapshot.sql against the database in the container,
/// saves the results to a file. The script runs a number of queries to capture the state
/// of both the database's structure and data.
///
/// # Arguments
///
/// * `container` - the docker container running postgres
/// * `db` - the database to snapshot
/// * `username` - the user to connect to the database with
/// * `path` - the path on the host to which the snapshot should be written
///
fn snapshot_db(container: &PostgresContainer, db: &str, username: &str, path: &Path) -> String {
    let snapshot = Path::new("/tmp/snapshot.txt");
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
        // do not ON_ERROR_STOP=1. some meta commands will not find objects for some schemas
        // and psql treats this as an error. this is expected, and we don't want the snapshot to
        // fail because of it. eat the error and continue
        //.args(["-v", "ON_ERROR_STOP=1"]) don't uncomment me!
        .args(["-o", snapshot.to_str().unwrap()])
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
    copy_out(container, snapshot, path);
    normalize_snapshot(path)
}

/// Uses pg_dump to create a logical backup
///
/// # Arguments
///
/// * `container` - the docker container running postgres
/// * `db` - the database to backup
/// * `username` - the user to run the backup
/// * `path` - the path where the logical dump file should be written on the host
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
/// * `path` - the path to the logical dump file on the host
///
fn restore_db(container: &PostgresContainer, db: &str, username: &str, path: &Path) {
    let dump = Path::new("/tmp/dump.sql");
    copy_in(container, path, dump);
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
        // do not ON_ERROR_STOP=1. some statements in the restore will fail. for example, setting
        // the comment on the timescaledb extension. this is highly unfortunate, but seemingly
        // unavoidable according to googling. eat the errors and continue. we will rely on the
        // snapshot to determine whether the restore was successful
        //.args(["-v", "ON_ERROR_STOP=1"]) don't uncomment me!
        .args(["-v", "VERBOSITY=verbose"])
        .args(["-f", dump.to_str().unwrap()])
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

/// Runs the after-create sql script in the container
fn after_create(container: &PostgresContainer) {
    psql_file(
        container,
        "db",
        "postgres",
        Path::new("/scripts/after-create.sql"),
    );
}

/// Runs the pre-dump sql script in the container
fn pre_dump(container: &PostgresContainer) {
    // run as postgres, create tsdbadmin user, and then set user tsdbadmin
    psql_file(
        container,
        "db",
        "tsdbadmin",
        Path::new("/scripts/pre-dump.sql"),
    );
}

/// Runs the pre-restore sql script in the container
fn pre_restore(container: &PostgresContainer) {
    psql_file(
        container,
        "db",
        "tsdbadmin",
        Path::new("/scripts/pre-restore.sql"),
    );
}

/// Runs the post-restore sql script in the container
fn post_restore(container: &PostgresContainer) {
    psql_file(
        container,
        "db",
        "tsdbadmin",
        Path::new("/scripts/post-restore.sql"),
    );
}

/// Runs the post-snapshot sql script in the container
fn post_snapshot(container: &PostgresContainer) {
    psql_file(
        container,
        "db",
        "tsdbadmin",
        Path::new("/scripts/post-snapshot.sql"),
    );
}

/// Removes the working directory if it exists, then creates it
fn make_working_dir(dir: &Path) {
    println!("temp dir at: {}", dir.to_str().unwrap());
    if dir.exists() {
        fs::remove_dir_all(dir).expect("failed to remove temp dir");
    }
    fs::create_dir_all(dir).expect("failed to create temp dir");
}

/// Performs all operations on the first database container
///
/// 1. creates the container
/// 2. adds metric, exemplar, and tracing data to it
/// 3. snapshots the database
/// 4. uses pg_dump to create a logical backup
/// 5. stops the container
/// 6. returns the snapshot
///
fn first_db(
    docker: &Cli,
    postgres_image: &str,
    volumes: Option<&Vec<(&str, &str)>>,
    dir: &Path,
    dump: &Path,
) -> String {
    let container = run_postgres(docker, postgres_image, "db", "postgres", volumes);
    after_create(&container);
    pre_dump(&container);
    let snapshot0 = snapshot_db(
        &container,
        "db",
        "postgres",
        dir.join("snapshot-0.txt").as_path(),
    );
    dump_db(&container, "db", "tsdbadmin", dump);
    container.stop();
    container.rm();
    snapshot0
}

/// Performs all operations on the second database container
///
/// 1. creates the container
/// 2. runs the pre-restore script
/// 3. uses the logical backup to restore the database
/// 4. runs the post-restore script
/// 5. snapshots the database
/// 6. runs the post-snapshot script to add more data to the database
/// 7. stops the container
/// 8. returns the snapshot
///
fn second_db(
    docker: &Cli,
    postgres_image: &str,
    volumes: Option<&Vec<(&str, &str)>>,
    dir: &Path,
    dump: &Path,
) -> String {
    let container = run_postgres(docker, postgres_image, "db", "postgres", volumes);
    after_create(&container);
    pre_restore(&container);
    restore_db(&container, "db", "tsdbadmin", dump);
    post_restore(&container);
    let snapshot1 = snapshot_db(
        &container,
        "db",
        "postgres",
        dir.join("snapshot-1.txt").as_path(),
    );
    post_snapshot(&container);
    container.stop();
    container.rm();
    snapshot1
}

/// Diffs the two snapshots.
/// Differences are printed to the console.
/// Returns a boolean. True indicates the two snapshots are identical
fn are_snapshots_equal(snapshot0: String, snapshot1: String) -> bool {
    let are_snapshots_equal = snapshot0 == snapshot1;
    if !are_snapshots_equal {
        let diff = TextDiff::from_lines(snapshot0.as_str(), snapshot1.as_str());
        for change in diff.iter_all_changes() {
            if change.tag() == ChangeTag::Equal {
                continue;
            }
            let sign = match change.tag() {
                ChangeTag::Delete => "-",
                ChangeTag::Insert => "+",
                ChangeTag::Equal => " ",
            };
            println!("{} {}", sign, change);
        }
    }
    are_snapshots_equal
}

/// Tests the process of dumping and restoring a database using pg_dump
#[test]
fn dump_restore_test() {
    let docker = clients::Cli::default();
    let postgres_image = postgres_image();
    let volumes = vec![(concat!(env!("CARGO_MANIFEST_DIR"), "/scripts"), "/scripts")];

    let dir = &env::temp_dir().join("promscale-dump-restore-test");
    make_working_dir(dir);
    let dump = dir.join("dump.sql");

    // create the first container, load it with data, snapshot it, and dump it
    let snapshot0 = first_db(&docker, &postgres_image, Some(&volumes), dir, &dump);

    // create the second container, restore into it, snapshot it, add more data
    let snapshot1 = second_db(&docker, &postgres_image, Some(&volumes), dir, &dump);

    // don't do `assert_eq!(snapshot0, snapshot1);`
    // it prints both entire snapshots and is impossible to read
    let are_snapshots_equal = are_snapshots_equal(snapshot0, snapshot1);
    assert!(are_snapshots_equal);
}
