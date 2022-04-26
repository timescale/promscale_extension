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
/// * `name` - the filename of the snapshot
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
    edit_snapshot(path)
}

/// Uses pg_dump to create a logical backup
///
/// # Arguments
///
/// * `container` - the docker container running postgres
/// * `db` - the database to backup
/// * `username` - the user to run the backup
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
///
fn restore_db(container: &PostgresContainer, db: &str, username: &str, path: &Path) {
    let dump = Path::new("/tmp/dump.sql");
    copy_in(container, path, dump);
    psql_file(container, db, username, dump);
}

/// Runs the pre-dump sql script in the container
fn pre_dump(container: &PostgresContainer) {
    psql_file(
        &container,
        "db",
        "postgres",
        Path::new("/scripts/pre-dump.sql"),
    );
}

/// Runs the pre-restore sql script in the container
fn pre_restore(container: &PostgresContainer) {
    psql_file(
        &container,
        "db",
        "postgres",
        Path::new("/scripts/pre-restore.sql"),
    );
}

/// Runs the post-restore sql script in the container
fn post_restore(container: &PostgresContainer) {
    psql_file(
        &container,
        "db",
        "postgres", // todo: use bob for this
        Path::new("/scripts/post-restore.sql"),
    );
}

/// Runs the post-snapshot sql script in the container
fn post_snapshot(container: &PostgresContainer) {
    psql_file(
        &container,
        "db",
        "bob",
        Path::new("/scripts/post-snapshot.sql"),
    );
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
/// 8. create more data to make sure things are still wired up correctly
/// 9. compare the two snapshots. they should be equal
#[test]
fn dump_restore_test() {
    let docker = clients::Cli::default();
    let postgres_image = postgres_image();
    let volumes = vec![(concat!(env!("CARGO_MANIFEST_DIR"), "/scripts"), "/scripts")];

    let dir = &env::temp_dir().join("promscale-dump-restore-test");
    println!("temp dir at: {}", dir.to_str().unwrap());
    if dir.exists() {
        fs::remove_dir_all(dir).expect("failed to remove temp dir");
    }
    fs::create_dir_all(dir).expect("failed to create temp dir");
    let dump = dir.join("dump.sql");

    // create the first container, load it with data, snapshot it, and dump it
    let snapshot0 = {
        let container = run_postgres(
            &docker,
            postgres_image.as_str(),
            "db",
            "postgres",
            Some(&volumes),
        );
        pre_dump(&container);
        let snapshot0 = snapshot_db(
            &container,
            "db",
            "bob",
            dir.join("snapshot-0.txt").as_path(),
        );
        dump_db(&container, "db", "postgres", &dump); // todo: dump using bob user
        container.stop();
        container.rm();
        snapshot0
    };

    // create the second container, restore into it, snapshot it
    let snapshot1 = {
        let container = run_postgres(
            &docker,
            postgres_image.as_str(),
            "db",
            "postgres",
            Some(&volumes),
        );
        pre_restore(&container);
        restore_db(&container, "db", "postgres", &dump);
        post_restore(&container);
        psql_cmd(&container, "db", "postgres", "grant prom_admin to bob;");
        let snapshot1 = snapshot_db(
            &container,
            "db",
            "bob",
            dir.join("snapshot-1.txt").as_path(),
        );
        post_snapshot(&container);
        container.stop();
        container.rm();
        snapshot1
    };

    // don't do `assert_eq!(snapshot0, snapshot1);`
    // it prints both entire snapshots and is impossible to read
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
    assert!(are_snapshots_equal);
}
