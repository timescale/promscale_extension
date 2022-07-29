use postgres::Client;
use regex::Regex;
use semver::Version;
use similar::{ChangeTag, TextDiff};
use std::fs::{create_dir_all, remove_dir_all, set_permissions, Permissions};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::{env, fs};
use test_common::postgres_container::connect;
use test_common::{PostgresContainer, PostgresContainerBlueprint};

/*

OBJECTIVE:
Ensure that a fresh install of the extension will produce the same results as starting
from a prior version of the extension and upgrading it.

APPROACH:
We have a candidate version that has been built into a docker image. This may be build locally on a
developer's machine, or in CI off a branch. We want to test the install vs upgrade using this
candidate image.

We start with a baseline. We use the candidate image to install the promscale extension from scratch
at the default version, which should be the latest version, which should also be the candidate
version. We "snapshot" the structure and data of the database to a text file.

Next, we want to compare this baseline snapshot to one produced by an upgrade process. We want to
mimic what a real-world user would do. So, we start with a "blessed" image -- ideally, a published
release image. We create the promscale extension at a "prior" version and shutdown the container.

We then create a new container using the candidate image and the existing data directory. We then
update the promscale extension to the latest version. We snapshot the structure and data of the
database to a file.

The snapshots produced by the baseline and the upgrade should be identical.

COMPLEXITIES:

* We need these tests to run locally on a developer's machine, and in CI.
* We should ideally test both "flavors" of our images: HA and Alpine. Images built on developers'
  machines with make are of the alpine "flavor". Both "flavors" are used in CI.
* We should ideally test with postgres versions 12, 13, and 14.
* We have had at least one issue with a release in which the upgrade failed because of a database
  migration that would not work if a given table was empty. So, we now have test scenarios both
  with and without data. See issue: https://github.com/timescale/promscale/issues/33
* We want to test with the immediately prior version of the promscale extension and the first
  version of the extension that can be installed without the connector.
* The default version of timescaledb in the "from" and "to" images may differ. We update the
  timescaledb extension in this case as well.

Variations we run:
┌───────┬────────┬────┬─────────┬───────┐
│ where │ flavor │ pg │  data   │ from  │
├───────┼────────┼────┼─────────┼───────┤
│ ci    │ alpine │ 12 │ with    │ first │
│ ci    │ alpine │ 12 │ with    │ prior │
│ ci    │ alpine │ 12 │ without │ first │
│ ci    │ alpine │ 12 │ without │ prior │
│ ci    │ alpine │ 13 │ with    │ first │
│ ci    │ alpine │ 13 │ with    │ prior │
│ ci    │ alpine │ 13 │ without │ first │
│ ci    │ alpine │ 13 │ without │ prior │
│ ci    │ alpine │ 14 │ with    │ first │
│ ci    │ alpine │ 14 │ with    │ prior │
│ ci    │ alpine │ 14 │ without │ first │
│ ci    │ alpine │ 14 │ without │ prior │
│ ci    │ ha     │ 12 │ with    │ first │
│ ci    │ ha     │ 12 │ with    │ prior │
│ ci    │ ha     │ 12 │ without │ first │
│ ci    │ ha     │ 12 │ without │ prior │
│ ci    │ ha     │ 13 │ with    │ first │
│ ci    │ ha     │ 13 │ with    │ prior │
│ ci    │ ha     │ 13 │ without │ first │
│ ci    │ ha     │ 13 │ without │ prior │
│ ci    │ ha     │ 14 │ with    │ first │
│ ci    │ ha     │ 14 │ with    │ prior │
│ ci    │ ha     │ 14 │ without │ first │
│ ci    │ ha     │ 14 │ without │ prior │
│ local │ alpine │ 12 │ with    │ first │
│ local │ alpine │ 12 │ with    │ prior │
│ local │ alpine │ 12 │ without │ first │
│ local │ alpine │ 12 │ without │ prior │
│ local │ alpine │ 13 │ with    │ first │
│ local │ alpine │ 13 │ with    │ prior │
│ local │ alpine │ 13 │ without │ first │
│ local │ alpine │ 13 │ without │ prior │
│ local │ alpine │ 14 │ with    │ first │
│ local │ alpine │ 14 │ with    │ prior │
│ local │ alpine │ 14 │ without │ first │
│ local │ alpine │ 14 │ without │ prior │
└───────┴────────┴────┴─────────┴───────┘
*/

enum FromVersion {
    First,
    Prior,
}

#[test]
fn upgrade_first_no_data_test() {
    test_upgrade(FromVersion::First, false);
}

#[test]
fn upgrade_first_with_data_test() {
    test_upgrade(FromVersion::First, true);
}

#[test]
fn upgrade_prior_no_data_test() {
    test_upgrade(FromVersion::Prior, false);
}

#[test]
fn upgrade_prior_with_data_test() {
    test_upgrade(FromVersion::Prior, true);
}

fn test_upgrade(from_version: FromVersion, with_data: bool) {
    // in local development, we want local/dev_promscale_extension:head-ts2-pg14
    // in ci, we want ghcr.io/timescale/dev_promscale_extension:<branch-name>-ts2.7.2-pg<version>
    // this image will be used for the baseline and for upgrading the version of promscale
    let to_image_uri = env::var("TS_DOCKER_IMAGE")
        .unwrap_or_else(|_| "local/dev_promscale_extension:head-ts2-pg14".to_string());

    // we need to know whether we are using an ha or alpine image in order to pick an appropriate
    // corresponding "from" image used the create the older version of promscale
    let flavor = match to_image_uri.starts_with("local/dev_promscale_extension") {
        true => "alpine",
        false => match to_image_uri.ends_with("-alpine") {
            true => "alpine",
            false => "ha",
        },
    };
    println!("image flavor: {}", &flavor);

    // we also need to know which version of postgres we have been instructed to use
    let pg_version = Regex::new("pg[0-9]{2}")
        .unwrap()
        .find(&to_image_uri)
        .unwrap()
        .as_str()
        .strip_prefix("pg")
        .unwrap();
    println!("postgresql version: {}", &pg_version);

    // a unique name for the test combination we are running
    let name = format!(
        "upgrade-from-{}-{}-{}-pg{}",
        match from_version {
            FromVersion::First => "first",
            FromVersion::Prior => "prior",
        },
        match with_data {
            true => "with-data",
            false => "no-data",
        },
        flavor,
        pg_version
    );
    println!("name: {}", name);

    // figure out which image we should start with in the upgrade process
    // based on alpine vs ha and postgres version
    let from_image_uri = if flavor == "ha" {
        // ha
        format!("timescale/timescaledb-ha:pg{}-ts2.7.1--latest", pg_version)
    } else {
        // alpine
        format!(
            "ghcr.io/timescale/dev_promscale_extension:master-ts2-pg{}",
            pg_version
        )
    };
    println!("from image {}", from_image_uri);
    println!("to image {}", to_image_uri);

    // in this directory we'll put our db snapshots we'll compare
    let working_dir = env::temp_dir().join(&name);
    if working_dir.exists() {
        remove_dir_all(&working_dir).expect("failed to remove working dir");
    }
    create_dir_all(&working_dir).expect("failed to create working dir");
    println!("working dir at {}", working_dir.to_str().unwrap());

    // for the database we're upgrading, we need to use two containers and the data_directory
    // needs to be persistent in this dir. we'll nest it inside the working directory
    let data_dir = working_dir.join("db");
    if !data_dir.exists() {
        create_dir_all(&data_dir).expect("failed to create working dir and data dir");
    }
    let permissions = Permissions::from_mode(0o777);
    set_permissions(&data_dir, permissions.clone())
        .expect("failed to chmod 0o777 on the data directory");
    let data_dir = data_dir.to_str().unwrap();
    println!("data dir at {}", &data_dir);

    // this dir has our sql scripts. we'll mount it into the docker containers and use them via psql
    let script_dir = concat!(env!("CARGO_MANIFEST_DIR"), "/scripts");
    println!("script dir at {}", script_dir);

    /**********************************************************************************************/
    // BASELINE
    println!("BASELINE");
    let baseline_blueprint = PostgresContainerBlueprint::new()
        .with_image_uri(to_image_uri.clone())
        .with_volume(script_dir, "/scripts")
        .with_env_var("PGDATA", "/var/lib/postgresql/data")
        .with_db("db")
        .with_user("postgres");
    let baseline_container = baseline_blueprint.run();
    let mut baseline_client = connect(&baseline_blueprint, &baseline_container);

    // determine the versions of the promscale extension we are supposed to upgrade from and to
    let (from_version, to_version) = {
        let (first_version, last_version, prior_version) =
            available_extension_versions(&mut baseline_client);
        (
            match from_version {
                FromVersion::First => first_version,
                FromVersion::Prior => prior_version,
            },
            last_version,
        )
    };
    println!("from promscale version: {}", from_version);
    println!("to promscale version: {}", to_version);

    // install the timescaledb extension at the default version for this image
    let to_timescaledb_version = install_timescaledb_ext(&mut baseline_client);

    // install the promscale extension at the "to" version
    install_promscale_ext(&mut baseline_client, &to_version);

    // load test data if configured to
    if with_data {
        load_data(&baseline_container);
    }

    // snapshot the database
    let baseline_snapshot: String = snapshot_db(
        baseline_container.id(),
        "db",
        "postgres",
        working_dir.join("baseline-snapshot.txt").as_path(),
    );

    // shut it down
    baseline_client
        .close()
        .expect("failed to close database connection");
    baseline_container.stop();

    /**********************************************************************************************/
    // UPGRADE FROM
    println!("UPGRADE FROM");
    let from_blueprint = PostgresContainerBlueprint::new()
        .with_image_uri(from_image_uri)
        .with_volume(script_dir, "/scripts")
        .with_volume(data_dir, "/var/lib/postgresql/data:z")
        .with_env_var("PGDATA", "/var/lib/postgresql/data")
        .with_db("db")
        .with_user("postgres");
    let from_container = from_blueprint.run();
    let mut from_client = connect(&from_blueprint, &from_container);

    // install the timescaledb extension at the default version
    let from_timescaledb_version = install_timescaledb_ext(&mut from_client);
    println!("from timescaledb version: {}", &from_timescaledb_version);
    println!("to timescaledb version: {}", &to_timescaledb_version);

    // if the "from" version is greater than the "to" version, then we have problems!
    assert!(from_timescaledb_version <= to_timescaledb_version);

    // install the promscale extension at the "from_version"
    install_promscale_ext(&mut from_client, &from_version);

    // load test data if configured to
    if with_data {
        load_data(&from_container);
    }

    // checkpoint
    from_client
        .execute("checkpoint", &[])
        .expect("failed to checkpoint");

    // shut it down
    from_client
        .close()
        .expect("failed to close database connection");
    from_container.stop();

    /**********************************************************************************************/
    // UPGRADE TO
    println!("UPGRADE TO");
    let to_blueprint = PostgresContainerBlueprint::new()
        .with_image_uri(to_image_uri)
        .with_volume(script_dir, "/scripts")
        .with_volume(data_dir, "/var/lib/postgresql/data:z")
        .with_env_var("PGDATA", "/var/lib/postgresql/data")
        .with_db("db")
        .with_user("postgres");
    let to_container = to_blueprint.run();
    println!("to_container id: {}", to_container.id());

    // upgrade the timescaledb extension if we need to
    if from_timescaledb_version != to_timescaledb_version {
        println!(
            "upgrading from timescaledb {} to {}",
            from_timescaledb_version, to_timescaledb_version
        );
        update_extension(
            to_container.id(),
            "postgres",
            "db",
            "timescaledb",
            &to_timescaledb_version,
        );
    }

    // update the promscale extension
    update_extension(
        to_container.id(),
        "postgres",
        "db",
        "promscale",
        &to_version,
    );

    // snapshot the database
    let upgraded_snapshot = snapshot_db(
        to_container.id(),
        "db",
        "postgres",
        working_dir.join("upgraded-snapshot.txt").as_path(),
    );

    // shut it down
    to_container.stop();

    // compare the snapshots
    let are_equal = are_snapshots_equal(baseline_snapshot, upgraded_snapshot);
    assert!(are_equal);
}

/// determines the first, last, and prior versions of the promscale extension available
fn available_extension_versions(client: &mut Client) -> (Version, Version, Version) {
    // version 0.1 won't parse correctly
    // version 0.5.3 and pre-releases of 0.5.3 were pulled due to a bug the broke upgrades
    let qry = r"select version 
    from pg_available_extension_versions 
    where name = 'promscale' 
    and version not in ('0.1', '0.5.3') and version not like '0.5.3-%';";
    let result = client
        .query(qry, &[])
        .expect("failed to select available extension versions");
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

/// runs a SQL script file in the docker container
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

/// runs the load-data sql script in the container
fn load_data(container: &PostgresContainer) {
    psql_file(
        container,
        "db",
        "postgres",
        Path::new("/scripts/load-data.sql"),
    );
}

/// copies a file out of a container to the host filesystem
fn copy_out(container_id: &str, src: &Path, dest: &Path) {
    if dest.exists() {
        fs::remove_file(dest).expect("failed to remove existing dest file");
    }
    let exit = Command::new("docker")
        .arg("cp")
        .arg(format!("{}:{}", &container_id, src.display()))
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

/// edits a snapshot file to account for acceptable differences
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

/// takes a snapshot of a database to a text file on the host filesystem
fn snapshot_db(container_id: &str, db: &str, username: &str, path: &Path) -> String {
    let snapshot = Path::new("/tmp/snapshot.txt");
    println!("snapshotting database {} via {} user...", db, username);
    let exit = Command::new("docker")
        .arg("exec")
        .arg(&container_id)
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
    copy_out(container_id, snapshot, path);
    normalize_snapshot(path)
}

/// diffs the two snapshots
fn are_snapshots_equal(snapshot0: String, snapshot1: String) -> bool {
    println!("comparing the snapshots...");
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
    } else {
        println!("snapshots are equal");
    }
    are_snapshots_equal
}

/// installs the timescaledb extension
fn install_timescaledb_ext(client: &mut Client) -> Version {
    client
        .execute("create extension if not exists timescaledb;", &[])
        .expect("failed to install the timescaledb extension");

    let result = client.query_one(
        "select extversion from pg_extension where extname = 'timescaledb'",
        &[],
    );
    Version::parse(
        result
            .expect("failed to determine extension version")
            .get(0),
    )
    .expect("failed to parse extension version")
}

/// installs the promscale extension at the specified version
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

/// updates an extension to a specific version
fn update_extension(
    container_id: &str,
    username: &str,
    db: &str,
    extension: &str,
    version: &Version,
) {
    let child = Command::new("docker")
        .arg("exec")
        .arg(&container_id)
        .arg("psql")
        .args(["-U", username])
        .args(["-d", db])
        .arg("-X") // the -X flag is important!! This prevents accidentally triggering the load of a previous TimescaleDB version on session startup.
        .arg("--no-password")
        .arg("--no-psqlrc")
        .arg("--no-readline")
        .arg("--echo-all")
        .args(["-v", "ON_ERROR_STOP=1"])
        .args([
            "-c",
            format!("alter extension {} update to '{}';", extension, &version).as_str(),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("failed to start psql to upgrade the extension");
    let output = child
        .wait_with_output()
        .expect("failed to wait for psql to exit");
    assert!(
        output.status.success(),
        "updating {} to version {} failed: {}",
        extension,
        &version,
        std::str::from_utf8(output.stderr.as_slice()).unwrap()
    );
}

/*
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
    blueprint: &PostgresContainerBlueprint,
    dir: &Path,
    with_data: bool,
) -> (Version, Version, Version, String) {
    let container = blueprint.run();
    let mut client = postgres_container::connect(&blueprint, &container);

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
    blueprint: &PostgresContainerBlueprint,
    dir: &Path,
    first: &Version,
    second: &Version,
    with_data: bool,
    baseline_snapshot: String,
) {
    let container = blueprint.run();
    let mut client = postgres_container::connect(&blueprint, &container);
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
    let blueprint = PostgresContainerBlueprint::new()
        .with_volume(concat!(env!("CARGO_MANIFEST_DIR"), "/scripts"), "/scripts")
        .with_db("db")
        .with_user("postgres");

    let dir = &env::temp_dir().join("promscale-upgrade-first-no-data-test");
    make_working_dir(dir);

    let (first_version, last_version, _, snapshot) = baseline(&blueprint, dir, false);

    println!("upgrading from {} to {}", first_version, last_version);
    upgrade(
        &blueprint,
        dir,
        &first_version,
        &last_version,
        false,
        snapshot,
    );
}

#[test]
fn upgrade_first_with_data_test() {
    let blueprint = PostgresContainerBlueprint::new()
        .with_volume(concat!(env!("CARGO_MANIFEST_DIR"), "/scripts"), "/scripts")
        .with_db("db")
        .with_user("postgres");

    let dir = &env::temp_dir().join("promscale-upgrade-first-with-data-test");
    make_working_dir(dir);

    let (first_version, last_version, _, snapshot) = baseline(&blueprint, dir, true);

    println!("upgrading from {} to {}", first_version, last_version);
    upgrade(
        &blueprint,
        dir,
        &first_version,
        &last_version,
        true,
        snapshot,
    );
}

#[test]
fn upgrade_prior_no_data_test() {
    let blueprint = PostgresContainerBlueprint::new()
        .with_volume(concat!(env!("CARGO_MANIFEST_DIR"), "/scripts"), "/scripts")
        .with_db("db")
        .with_user("postgres");

    let dir = &env::temp_dir().join("promscale-upgrade-prior-no-data-test");
    make_working_dir(dir);

    let (_, last_version, prior_version, snapshot) = baseline(&blueprint, dir, false);

    println!("upgrading from {} to {}", prior_version, last_version);
    upgrade(
        &blueprint,
        dir,
        &prior_version,
        &last_version,
        false,
        snapshot,
    );
}

#[test]
fn upgrade_prior_with_data_test() {
    let blueprint = PostgresContainerBlueprint::new()
        .with_volume(concat!(env!("CARGO_MANIFEST_DIR"), "/scripts"), "/scripts")
        .with_db("db")
        .with_user("postgres");

    let dir = &env::temp_dir().join("promscale-upgrade-prior-with-data-test");
    make_working_dir(dir);

    let (_, last_version, prior_version, snapshot) = baseline(&blueprint, dir, true);

    println!("upgrading from {} to {}", prior_version, last_version);
    upgrade(
        &blueprint,
        dir,
        &prior_version,
        &last_version,
        true,
        snapshot,
    );
}
*/
