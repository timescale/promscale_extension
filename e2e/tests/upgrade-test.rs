use postgres::Client;
use regex::Regex;
use semver::Version;
use similar::{ChangeTag, TextDiff};
use std::path::Path;
use std::process::Command;
use std::{env, fs};
use test_common::{PostgresContainer, PostgresTestHarness};

/// Removes the working directory if it exists, then creates it
fn make_working_dir(dir: &Path) {
    println!("temp dir at: {}", dir.to_str().unwrap());
    if dir.exists() {
        fs::remove_dir_all(dir).expect("failed to remove temp dir");
    }
    fs::create_dir_all(dir).expect("failed to create temp dir");
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

/// Runs the load-data sql script in the container
fn load_data(container: &PostgresContainer) {
    psql_file(
        container,
        "db",
        "postgres",
        Path::new("/scripts/load-data.sql"),
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
fn copy_out(container: &PostgresContainer, src: &Path, dest: &Path) {
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

    // chunks have constraints defined on the time column. the constants will be slightly off and that's okay
    let re = Regex::new(
        "\"time\" (>=|<) '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}.[0-9]{0,6}\\+00'",
    )
    .unwrap();
    let snapshot = re.replace_all(&snapshot, "\"time\" >= '1982-01-06 01:02:03.123456+00'");

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

fn available_extension_versions(client: &mut Client) -> (Version, Version, Version) {
    let result = client
        .query(
            "select version from pg_available_extension_versions where name = 'promscale' and version != '0.1';",
            &[],
        )
        .unwrap();
    let mut versions: Vec<Version> = vec![];
    for row in result {
        let x: &str = row.get(0);
        let version = match Version::parse(x) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if version < Version::parse("0.5.0").unwrap() {
            continue;
        }
        versions.push(version);
    }
    assert!(versions.len() >= 2);
    versions.sort();
    let first = versions[0].to_owned();
    let last = versions.pop().unwrap();
    let prior = versions.pop().unwrap();
    (first, last, prior)
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

fn install_timescaledb_ext(client: &mut Client) {
    client
        .execute("create extension if not exists timescaledb;", &[])
        .expect("failed to install the timescaledb extension");
}

fn install_promscale_ext(client: &mut Client, version: &Version) {
    client
        .execute(
            format!(
                "create extension promscale version '{}';",
                version.to_string()
            )
            .as_str(),
            &[],
        )
        .expect("failed to install the promscale extension");
}

fn update_promscale_ext(client: &mut Client, version: &Version) {
    client
        .execute(
            format!(
                "alter extension promscale update to '{}';",
                version.to_string()
            )
            .as_str(),
            &[],
        )
        .expect("failed to update the promscale extension");
}

fn baseline(
    harness: &PostgresTestHarness,
    dir: &Path,
    with_data: bool,
) -> (Version, Version, Version, String) {
    let container = harness.run();
    let mut client = test_common::connect(&harness, &container);

    let (first_version, last_version, prior_version) = available_extension_versions(&mut client);

    install_timescaledb_ext(&mut client);
    install_promscale_ext(&mut client, &last_version);
    let snapshot: String = if !with_data {
        snapshot_db(
            &container,
            "db",
            "postgres",
            dir.join(format!("snapshot-baseline-{}-no-data.txt", last_version))
                .as_path(),
        )
    } else {
        load_data(&container);
        snapshot_db(
            &container,
            "db",
            "postgres",
            dir.join(format!("snapshot-baseline-{}-with-data.txt", last_version))
                .as_path(),
        )
    };
    container.stop();

    (first_version, last_version, prior_version, snapshot)
}

fn upgrade(
    harness: &PostgresTestHarness,
    dir: &Path,
    first: &Version,
    second: &Version,
    with_data: bool,
    baseline_snapshot: String,
) {
    let container = harness.run();
    let mut client = test_common::connect(&harness, &container);
    install_timescaledb_ext(&mut client);
    install_promscale_ext(&mut client, first);
    if with_data {
        load_data(&container);
    }
    update_promscale_ext(&mut client, second);
    let snapshot = snapshot_db(
        &container,
        "db",
        "postgres",
        dir.join(format!(
            "snapshot-{}-{}-{}.txt",
            first,
            second,
            if with_data { "with-data" } else { "no-data" }
        ))
        .as_path(),
    );
    container.stop();
    let are_equal = are_snapshots_equal(baseline_snapshot, snapshot);
    assert!(are_equal);
}

#[test]
fn upgrade_first_no_data_test() {
    let harness = PostgresTestHarness::new()
        .with_volume(concat!(env!("CARGO_MANIFEST_DIR"), "/scripts"), "/scripts")
        .with_db("db")
        .with_user("postgres");

    let dir = &env::temp_dir().join("promscale-upgrade-first-no-data-test");
    make_working_dir(dir);

    let (first_version, last_version, _, snapshot) = baseline(&harness, dir, false);

    println!("upgrading from {} to {}", first_version, last_version);
    upgrade(
        &harness,
        dir,
        &first_version,
        &last_version,
        false,
        snapshot,
    );
}

#[test]
fn upgrade_first_with_data_test() {
    let harness = PostgresTestHarness::new()
        .with_volume(concat!(env!("CARGO_MANIFEST_DIR"), "/scripts"), "/scripts")
        .with_db("db")
        .with_user("postgres");

    let dir = &env::temp_dir().join("promscale-upgrade-first-with-data-test");
    make_working_dir(dir);

    let (first_version, last_version, _, snapshot) = baseline(&harness, dir, true);

    println!("upgrading from {} to {}", first_version, last_version);
    upgrade(&harness, dir, &first_version, &last_version, true, snapshot);
}

#[test]
fn upgrade_prior_no_data_test() {
    let harness = PostgresTestHarness::new()
        .with_volume(concat!(env!("CARGO_MANIFEST_DIR"), "/scripts"), "/scripts")
        .with_db("db")
        .with_user("postgres");

    let dir = &env::temp_dir().join("promscale-upgrade-prior-no-data-test");
    make_working_dir(dir);

    let (_, last_version, prior_version, snapshot) = baseline(&harness, dir, false);

    println!("upgrading from {} to {}", prior_version, last_version);
    upgrade(
        &harness,
        dir,
        &prior_version,
        &last_version,
        false,
        snapshot,
    );
}

#[test]
fn upgrade_prior_with_data_test() {
    let harness = PostgresTestHarness::new()
        .with_volume(concat!(env!("CARGO_MANIFEST_DIR"), "/scripts"), "/scripts")
        .with_db("db")
        .with_user("postgres");

    let dir = &env::temp_dir().join("promscale-upgrade-prior-with-data-test");
    make_working_dir(dir);

    let (_, last_version, prior_version, snapshot) = baseline(&harness, dir, true);

    println!("upgrading from {} to {}", prior_version, last_version);
    upgrade(&harness, dir, &prior_version, &last_version, true, snapshot);
}
