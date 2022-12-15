//! End-to-end tests to ensure that different upgrade paths have the same result
//!
//! ## Objective
//! These tests ensure that a fresh install of the extension produces the same
//! results as starting from a prior version of the extension and upgrading it.
//! It does so by comparing the database objects in the database.
//!
//! For full correctness, we run this procedure for both for the previously
//! released version of the extension, as well as the first released extension
//! version. This should catch issues like those in the following situation:
//!
//!   Assume we have an first version 1 and a new version 3.
//!   In version 2 we introduce the procedure foo().
//!   In version 3 we drop the procedure foo().
//!
//!   We could incorrectly implement the procedure drop in two ways:
//!   1. We use `DROP FUNCTION IF EXISTS foo();` (foo is a procedure, not a
//!      function).
//!   2. We use `DROP PROCEDURE foo();` (this is missing `IF EXISTS`)
//!
//!   Mistake 1 would only be caught by the version 2 -> version 3 upgrade
//!   test, because version 1 has no function foo. Mistake 2 would only be
//!   caught by the version 1 -> version 3 upgrade test, because version 1 has
//!   no function foo.
//!
//! ## Approach
//! We have a candidate version that has been built into a docker image. This
//! may be build locally on a developer's machine, or in CI off a branch. We
//! want to test the install vs upgrade using this candidate image.
//!
//! We start with a baseline. We use the candidate image to install the
//! promscale extension from scratch at the default version, which should be
//! the latest version, which should also be the candidate version. We
//! "snapshot" the structure and data of the database to a text file.
//!
//! Next, we want to compare this baseline snapshot to one produced by an
//! upgrade process. We want to mimic what a real-world user would do. So, we
//! start with a "blessed" image -- ideally, a published release image. We
//! create the promscale extension at a "prior" version and shutdown the
//! container.
//!
//! We then create a new container using the candidate image and the existing
//! data directory. We then update the promscale extension to the latest
//! version. We snapshot the structure and data of the database to a file.
//!
//! The snapshots produced by the baseline and the upgrade should be identical,
//! aside from some minor differences, which we manually clean up.
//!
//! ## Complexities
//!
//! * We need these tests to run locally on a developer's machine, and in CI.
//! * We should ideally test both "flavors" of our images: HA and Alpine.
//!   Images built on developers' machines with make are of the alpine
//!   "flavor". Both "flavors" are used in CI.
//! * We want to test with postgres versions 12, 13, and 14.
//! * We have had at least one issue with a release in which the upgrade failed
//!   because of a database migration that would not work if a given table was
//!   empty. So, we now have test scenarios both with and without data. See
//!   issue: https://github.com/timescale/promscale/issues/33
//! * We want to test with the immediately prior version of the promscale
//!   extension and the first version of the extension that can be installed
//!   without the connector.
//! * The default version of timescaledb in the "from" and "to" images may
//!   differ. We update the timescaledb extension in this case as well.
use crate::config::{
    ALPINE_WITH_EXTENSION_LAST_RELEASED_PREFIX, HA_WITH_LAST_RELEASED_EXTENSION_PG12,
    HA_WITH_LAST_RELEASED_EXTENSION_PG13, HA_WITH_LAST_RELEASED_EXTENSION_PG14,
};
use crate::util::debug_lines;
use duct::cmd;
use log::{info, warn};
use postgres::Client;
use regex::Regex;
use semver::Version;
use similar::{ChangeTag, TextDiff};
use std::fmt::{Display, Formatter};
use std::fs::{create_dir_all, remove_dir_all, set_permissions, Permissions};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;
use std::{env, fs};
use tempdir::TempDir;
use test_common::postgres_container::{connect, PgVersion};
use test_common::{PostgresContainer, PostgresContainerBlueprint};

mod config;
mod util;

enum FromVersion {
    First,
    Prior,
}

impl Display for FromVersion {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            FromVersion::First => write!(f, "first"),
            FromVersion::Prior => write!(f, "prior"),
        }
    }
}

enum Flavor {
    Alpine,
    HA,
}

impl Display for Flavor {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Flavor::Alpine => {
                write!(f, "alpine")
            }
            Flavor::HA => {
                write!(f, "ha")
            }
        }
    }
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
    let _ = pretty_env_logger::try_init();

    // in local development, we want local/dev_promscale_extension:head-ts2-pg<version>
    // in ci, we want ghcr.io/timescale/dev_promscale_extension:<branch-name>-ts2.<minor>.<patch>-pg<version>
    // this image will be used for the baseline and for upgrading the version of promscale
    let to_image_uri = env::var("TS_DOCKER_IMAGE")
        .unwrap_or_else(|_| "local/dev_promscale_extension:head-ts2-pg14".to_string());

    // we need to know whether we are using an ha or alpine image in order to pick an appropriate
    // corresponding "from" image used the create the older version of promscale
    let flavor = determine_image_flavor(&to_image_uri);
    info!("image flavor: {}", &flavor);

    // we also need to know which version of postgres we have been instructed to use
    let pg_version = determine_postgres_version(&to_image_uri).unwrap();
    info!("postgresql version: {}", &pg_version);

    // a unique name for the test combination we are running
    let name = format!(
        "upgrade-from-{}-{}-{}-pg{}",
        from_version,
        match with_data {
            true => "with-data",
            false => "no-data",
        },
        flavor,
        pg_version
    );

    // figure out which image we should start with in the upgrade process
    // based on alpine vs ha and postgres version
    let from_image_uri = if let Some(img) = from_image(&flavor, &pg_version, &from_version) {
        img
    } else {
        info!(
            "from image is not defined for the selected flavor {} and PG version {}",
            flavor, pg_version
        );
        return;
    };
    info!("from image {}", from_image_uri);
    info!("to image {}", to_image_uri);

    // we'll put our db snapshots to compare in this directory
    let temp_dir = TempDir::new(&name).expect("unable to create working dir");
    let working_dir = temp_dir.path();
    if working_dir.exists() {
        remove_dir_all(&working_dir).expect("failed to remove working dir");
    }
    create_dir_all(&working_dir).expect("failed to create working dir");
    info!("working dir at {}", working_dir.to_str().unwrap());

    // for the database we're upgrading, we need to use two containers and the data_directory
    // needs to be persistent in this dir. we'll nest it inside the working directory
    let data_dir = working_dir.join("db");
    if !data_dir.exists() {
        create_dir_all(&data_dir).expect("failed to create working dir and data dir");
    }
    // We need to chmod 777 this directory so that the HA image's initdb can create a subdirectory
    let permissions = Permissions::from_mode(0o777);
    set_permissions(&data_dir, permissions.clone())
        .expect("failed to chmod 0o777 on the data directory");
    let data_dir = data_dir.to_str().unwrap();
    info!("data dir at {}", &data_dir);

    // this dir has our sql scripts. we'll mount it into the docker containers and use them via psql
    let script_dir = concat!(env!("CARGO_MANIFEST_DIR"), "/scripts");
    info!("script dir at {}", script_dir);

    /**********************************************************************************************/
    // BASELINE
    info!("BASELINE");
    let baseline_blueprint = PostgresContainerBlueprint::new()
        .with_image_uri(to_image_uri.clone())
        .with_volume(script_dir, "/scripts")
        .with_env_var("PGDATA", "/var/lib/postgresql/data")
        .with_db("db")
        .with_user("postgres");
    let baseline_container = baseline_blueprint.run();
    let mut baseline_client = connect(&baseline_blueprint, &baseline_container);

    // determine the versions of the promscale extension we are supposed to upgrade from and to
    let (first_version, last_version, prior_version) =
        available_extension_versions(&mut baseline_client);
    let from_version = match from_version {
        FromVersion::First => first_version,
        FromVersion::Prior => prior_version,
    };
    let to_version = last_version;
    info!("from promscale version: {}", from_version);
    info!("to promscale version: {}", to_version);

    // install the timescaledb extension at the default version for this image
    let to_timescaledb_version = install_extension(&mut baseline_client, "timescaledb");
    drop_toolkit_extension(&mut baseline_client);

    // install the promscale extension at the "to" version
    install_extension_version(&mut baseline_client, "promscale", Some(to_version.clone()));

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
    // The HA image requires that we map chown 777'd parent directory in, while
    // the alpine image requires that we map the data directory in.
    let volume_map_path = match flavor {
        Flavor::Alpine => "/var/lib/postgresql/data",
        Flavor::HA => "/var/lib/postgresql",
    };
    info!("UPGRADE FROM");
    let from_blueprint = PostgresContainerBlueprint::new()
        .with_image_uri(from_image_uri)
        .with_volume(script_dir, "/scripts")
        .with_volume(data_dir, volume_map_path)
        .with_env_var("PGDATA", "/var/lib/postgresql/data")
        .with_db("db")
        .with_user("postgres");
    info!("run container");
    let from_container = from_blueprint.run();
    info!("connect");
    let mut from_client = connect(&from_blueprint, &from_container);

    // install the timescaledb extension at the default version
    info!("install ext");
    let from_timescaledb_version = install_extension(&mut from_client, "timescaledb");
    drop_toolkit_extension(&mut from_client);
    info!("from timescaledb version: {}", &from_timescaledb_version);
    info!("to timescaledb version: {}", &to_timescaledb_version);

    // if the "from" version is greater than the "to" version, then we have problems!
    assert!(from_timescaledb_version <= to_timescaledb_version);

    // install the promscale extension at the "from_version"
    install_extension_version(&mut from_client, "promscale", Some(from_version));

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
    info!("UPGRADE TO");
    let to_blueprint = PostgresContainerBlueprint::new()
        .with_image_uri(to_image_uri)
        .with_volume(script_dir, "/scripts")
        .with_volume(data_dir, volume_map_path)
        .with_env_var("PGDATA", "/var/lib/postgresql/data")
        .with_db("db")
        .with_user("postgres");
    let to_container = to_blueprint.run();
    info!("to_container id: {}", to_container.id());

    let mut to_client = connect(&to_blueprint, &to_container);

    // upgrade the timescaledb extension if we need to
    if from_timescaledb_version != to_timescaledb_version {
        info!(
            "upgrading from timescaledb {} to {}",
            from_timescaledb_version, to_timescaledb_version
        );
        update_extension(&mut to_client, "timescaledb", &to_timescaledb_version);
    }

    // update the promscale extension
    update_extension(&mut to_client, "promscale", &to_version);

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

fn from_image(
    flavor: &Flavor,
    pg_version: &PgVersion,
    from_version: &FromVersion,
) -> Option<String> {
    match flavor {
        Flavor::Alpine => match from_version {
            // Our timescaledev images are deprecated, but they are the only option for an alpine
            // image at the moment. They also are nicely tagged with the exact extension version.
            FromVersion::First => Some(format!(
                "timescaledev/promscale-extension:0.5.0-ts2.6.1-pg{}",
                pg_version
            ))
            .filter(|_| *pg_version != PgVersion::V15),
            FromVersion::Prior => Some(format!(
                "{}{}",
                ALPINE_WITH_EXTENSION_LAST_RELEASED_PREFIX, pg_version
            ))
            .filter(|_| *pg_version != PgVersion::V15),
        },
        Flavor::HA => match from_version {
            // The timescaledb-ha docker images aren't tagged with the version of the promscale
            // extension that they contain, so we need to keep a map of exact image tags (with
            // patch version) for the first release (with extension 0.5.0) and the prior release.
            FromVersion::First => match pg_version {
                PgVersion::V15 => None,
                PgVersion::V14 => Some(String::from("timescale/timescaledb-ha:pg14.2-ts2.6.1-p5")),
                PgVersion::V13 => Some(String::from("timescale/timescaledb-ha:pg13.6-ts2.6.1-p5")),
                PgVersion::V12 => Some(String::from("timescale/timescaledb-ha:pg12.10-ts2.6.1-p2")),
            },
            FromVersion::Prior => match pg_version {
                PgVersion::V15 => None,
                PgVersion::V14 => Some(String::from(HA_WITH_LAST_RELEASED_EXTENSION_PG14)),
                PgVersion::V13 => Some(String::from(HA_WITH_LAST_RELEASED_EXTENSION_PG13)),
                PgVersion::V12 => Some(String::from(HA_WITH_LAST_RELEASED_EXTENSION_PG12)),
            },
        },
    }
}

/// Looks at the name of a Docker image to determine if it is alpine or HA
fn determine_image_flavor(docker_image: &str) -> Flavor {
    // Note: here we just look at the image name. It would be more accurate to
    // introspect the actual image, but for now this works.
    match docker_image.starts_with("local/dev_promscale_extension") {
        true => Flavor::Alpine,
        false => match docker_image.ends_with("-alpine") {
            true => Flavor::Alpine,
            false => Flavor::HA,
        },
    }
}

/// Looks at the name of a Docker image to determine the postgres version
fn determine_postgres_version(docker_image: &str) -> Result<PgVersion, String> {
    // Note: here we just look at the image name. It would be more accurate to
    // introspect the actual image, but for now this works.
    let pg_version = Regex::new("pg[0-9]{2}")
        .unwrap()
        .find(docker_image)
        .unwrap()
        .as_str()
        .strip_prefix("pg")
        .unwrap();
    PgVersion::try_from(pg_version)
}

/// determines the first, last, and prior versions of the promscale extension available
fn available_extension_versions(client: &mut Client) -> (Version, Version, Version) {
    // version 0.1 won't parse correctly
    // version 0.5.3 and pre-releases of 0.5.3 were pulled due to a bug the broke upgrades
    let qry = r#"
        SELECT version
        FROM pg_available_extension_versions
        WHERE name = 'promscale'
        AND version NOT IN ('0.1', '0.5.3') AND version NOT LIKE '0.5.3-%';
    "#;
    let result = client
        .query(qry, &[])
        .expect("failed to select available extension versions");
    let mut versions: Vec<Version> = vec![];
    for row in result {
        let x: &str = row.get(0);
        let version = match Version::parse(x) {
            Ok(v) => v,
            Err(e) => {
                warn!("Unable to parse version '{}': {}", x, e);
                continue;
            }
        };
        if version < Version::new(0, 5, 0) {
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
    info!("executing psql script {}...", path.display());
    let output = cmd!(
        "docker",
        "exec",
        container.id(),
        "psql",
        "-U",
        username,
        "-d",
        db,
        "--no-password",
        "--no-psqlrc",
        "--no-readline",
        "--echo-all",
        "-v",
        "ON_ERROR_STOP=1",
        "-f",
        path.to_str().unwrap()
    )
    .stderr_to_stdout()
    .stdout_capture()
    .unchecked()
    .run()
    .unwrap();
    debug_lines(output.stdout);
    assert!(
        output.status.success(),
        "executing psql script {} failed: {}",
        path.display(),
        output.status
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
    info!("snapshotting database {} via {} user...", db, username);
    let output = cmd!(
        "docker",
        "exec",
        &container_id,
        "psql",
        "-U",
        username,
        "-d",
        db,
        "--no-password",
        "--no-psqlrc",
        "--no-readline",
        "--echo-all", // do not ON_ERROR_STOP=1. some meta commands will not find objects for some schemas
        // and psql treats this as an error. this is expected, and we don't want the snapshot to
        // fail because of it. eat the error and continue
        //.args(["-v", "ON_ERROR_STOP=1"]) don't uncomment me!
        "-o",
        snapshot.to_str().unwrap(),
        "-f",
        "/scripts/snapshot.sql"
    )
    .stderr_to_stdout()
    .stdout_capture()
    .run()
    .unwrap();
    debug_lines(output.stdout);
    assert!(
        output.status.success(),
        "snapshotting the database {} via {} user failed: {}",
        db,
        username,
        output.status
    );
    copy_out(container_id, snapshot, path);
    normalize_snapshot(path)
}

/// diffs the two snapshots
fn are_snapshots_equal(snapshot0: String, snapshot1: String) -> bool {
    info!("comparing the snapshots...");
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
            info!("{} {}", sign, change);
        }
    } else {
        info!("snapshots are equal");
    }
    are_snapshots_equal
}

/// Drops the toolkit extension
fn drop_toolkit_extension(client: &mut Client) {
    // Some docker images may also have timescaledb_toolkit installed in a
    // template, which messes with these tests because toolkit was not always
    // present. We can just drop it, it's not needed for the upgrade tests.
    client
        .execute("DROP EXTENSION IF EXISTS timescaledb_toolkit;", &[])
        .expect("failed to drop the toolkit extension");
}

/// Installs an extension at the default version
fn install_extension(client: &mut Client, extension_name: &str) -> Version {
    install_extension_version(client, extension_name, None)
}

/// Installs an extension at the specified version
fn install_extension_version(
    client: &mut Client,
    extension_name: &str,
    version: Option<Version>,
) -> Version {
    let version_specifier = version
        .map(|v| format!("VERSION '{}'", v.to_string()))
        .unwrap_or(String::new());
    client
        .execute(
            &format!(
                "CREATE EXTENSION IF NOT EXISTS {} {};",
                extension_name, version_specifier
            ),
            &[],
        )
        .expect("failed to install the extension");

    let result = client.query_one(
        &format!(
            "SELECT extversion FROM pg_extension WHERE extname = '{}'",
            extension_name
        ),
        &[],
    );
    Version::parse(
        result
            .expect("failed to determine extension version")
            .get(0),
    )
    .expect("failed to parse extension version")
}

/// Updates an extension to a specific version
fn update_extension(client: &mut Client, extension: &str, version: &Version) {
    client
        .execute(
            &format!(
                "ALTER EXTENSION {} UPDATE TO '{}'",
                extension,
                version.to_string()
            ),
            &[],
        )
        .expect("extension upgrade failed");
}
