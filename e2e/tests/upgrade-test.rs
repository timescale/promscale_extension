extern crate core;

use postgres::Client;
use regex::Regex;
use semver::Version;
use similar::{ChangeTag, TextDiff};
use std::fs::{create_dir_all, remove_dir_all, set_permissions, Permissions};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::{env, fs, thread};

// We expect the upgrade process to produce the same results as freshly installing the extension.
// These tests enforce that expectation.
//
// In each of the upgrade test, we first produce a baseline snapshot. To do so, we create a
// container using the docker image of the extension tagged as "latest". In this container, we
// create the extension at the default version, which ought to be the latest version. Then, we
// optionally create data using the extension APIs. Finally, we snapshot the state of the database
// to a text file.
//
// Next, we create another container using the docker image of the extension tagged as "latest".
// This container will use a docker volume mapping the postgres data dir to a host temp dir.
// In this container, we create the extension at either the "first" version, or the "prior" version.
// For our purposes, the "first" version ought to be 0.5.0 as this is the first
// version in which the extension is able to install itself without the connector. The "prior"
// version is the version just before the latest. These versions are determined using
// pg_available_extension_versions. Then, we optionally create data using the extension APIs,
// checkpoint the database, and stop the container.
//
// Then, we use the local docker image by default to create another container on top of the existing
// data dir. In CI, the docker image is specified by env var. In this container, we update the
// extension to the latest version and then snapshot the database to a text file.
//
// Finally, we compare the two database snapshots which should be identical.
//
// We have had at least one issue with a release in which the upgrade failed because of a database
// migration that would not work if a given table was empty. So, we now have test scenarios both
// with and without data. See issue: https://github.com/timescale/promscale/issues/330
//
// In CI, we run workflows with images based on both the "ha" image and alpine. The two image types
// have the postgres data dir mapped to different paths. This is irritating. If the default image
// starts with "ghcr.io/timescale/dev_promscale_extension:" then we assume we are running in CI.
// Otherwise, we assume we are running on a developer's machine.

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
    let pg_version = pg_version_from_image_uri(&to_image_uri);
    println!("postgresql version: {}", &pg_version);

    // are we running in ci?
    // https://docs.github.com/en/actions/learn-github-actions/environment-variables#default-environment-variables
    let is_ci = env::var("CI").is_ok();
    println!("running in ci: {}", is_ci);

    // pick the appropriate corresponding "from" image used the create the older version of promscale
    let from_image_uri = image_uri_from_flavor_pg_version(&flavor, &pg_version);
    println!("from image {}", from_image_uri);
    println!("to image {}", to_image_uri);

    // set up some working directories

    // this dir has our sql scripts. we'll mount it into the docker containers and use them via psql
    let script_dir = concat!(env!("CARGO_MANIFEST_DIR"), "/scripts");

    let name = name(&from_version, with_data, flavor, pg_version);

    // in this directory we'll put our db snapshots we'll compare
    let working_dir = env::temp_dir().join(&name);
    if working_dir.exists() {
        remove_dir_all(&working_dir).expect("failed to remove working dir");
    }
    create_dir_all(&working_dir).expect("failed to create working dir");
    println!("working dir at {}", working_dir.to_str().unwrap());

    // for the database we're upgrading, we need to use two containers and the data_directory
    // needs to be persistent in this dir
    let data_dir = working_dir.clone().join("db");
    if !data_dir.exists() {
        create_dir_all(&data_dir).expect("failed to create working dir and data dir");
    }
    let permissions = Permissions::from_mode(0o777);
    set_permissions(&data_dir, permissions.clone())
        .expect("failed to chmod 0o777 on the data directory");
    let data_dir = data_dir.to_str().unwrap();
    println!("data dir at {}", &data_dir);

    // BASELINE
    // create a container using the target image
    // determine the available extension versions and the postgres major version
    // install the timescaledb extension and the promscale extension at the to_version
    // optionally load test data
    // snapshot the database
    let (from_version, to_version, to_timescaledb_version, baseline_snapshot) = {
        println!("BASELINE");
        let child = Command::new("docker")
            .arg("run")
            .arg("-d")
            .args([
                "--mount",
                format!("type=bind,src={},dst=/scripts", script_dir).as_str(),
            ])
            .args(["--env", "PGDATA=/var/lib/postgresql/data/data"])
            .args(["--env", "POSTGRES_HOST_AUTH_METHOD=trust"])
            .args(["--env", "POSTGRES_DB=db"])
            .args(["--env", "POSTGRES_USER=postgres"])
            .args(["--env", "POSTGRES_PASSWORD=password"])
            .args(["-p", "5554:5432"])
            .arg(&to_image_uri)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("failed to create and run the docker container");
        let output = child
            .wait_with_output()
            .expect("failed to wait on docker run");
        assert!(
            output.status.success(),
            "docker run failed {}",
            std::str::from_utf8(output.stderr.as_slice()).expect("stderr is not valid utf8")
        );
        let baseline_container_id = std::str::from_utf8(output.stdout.as_slice())
            .expect("stdout is not valid utf8")
            .trim()
            .to_string();
        assert_ne!(baseline_container_id, "");
        println!("baseline_container_id: {}", &baseline_container_id);
        thread::sleep(std::time::Duration::from_secs(5));
        wait_for_pg_ready(&baseline_container_id);
        thread::sleep(std::time::Duration::from_secs(5));
        //wait_for_log_msg(&baseline_container_id);
        let mut baseline_client = Client::connect(
            "postgres://postgres:password@localhost:5554/db",
            postgres::NoTls,
        )
        .expect("failed to connect to postgres");

        let (first_version, last_version, prior_version) =
            available_extension_versions(&mut baseline_client);

        let to_timescaledb_version = install_timescaledb_ext(&mut baseline_client);
        install_promscale_ext(&mut baseline_client, &last_version);
        if with_data {
            load_data(&baseline_container_id);
        }
        let snapshot: String = snapshot_db(
            &baseline_container_id,
            "db",
            "postgres",
            working_dir
                .join(format!(
                    "snapshot-baseline-{}-{}.txt",
                    last_version,
                    match with_data {
                        true => "with-data",
                        false => "no-data",
                    }
                ))
                .as_path(),
        );
        stop_container(&baseline_container_id);
        let from_version = match from_version {
            FromVersion::First => first_version,
            FromVersion::Prior => prior_version,
        };
        (from_version, last_version, to_timescaledb_version, snapshot)
    };
    println!("from promscale version {}", from_version);
    println!("to promscale version {}", to_version);

    // UPGRADE FROM
    // create a container using the latest image
    // map postgres' data dir to a temp dir
    // install timescaledb and promscale at the from_version
    // optionally load test data
    let from_timescaledb_version = {
        println!("UPGRADE FROM");

        let child = Command::new("docker")
            .arg("run")
            .arg("-d")
            //.args(["--name", &name])
            .args([
                "--mount",
                format!("type=bind,src={},dst=/scripts", script_dir).as_str(),
            ])
            .args([
                "--mount",
                format!("type=bind,src={},dst=/var/lib/postgresql/data", data_dir).as_str(),
            ])
            .args(["--env", "PGDATA=/var/lib/postgresql/data/data"])
            .args(["--env", "POSTGRES_HOST_AUTH_METHOD=trust"])
            .args(["--env", "POSTGRES_DB=db"])
            .args(["--env", "POSTGRES_USER=postgres"])
            .args(["--env", "POSTGRES_PASSWORD=password"])
            .args(["-p", "5555:5432"])
            .arg(from_image_uri)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("failed to create and run the docker container");
        let output = child
            .wait_with_output()
            .expect("failed to wait on docker run");
        assert!(
            output.status.success(),
            "docker run failed {}",
            std::str::from_utf8(output.stderr.as_slice()).expect("stderr is not valid utf8")
        );
        let from_container_id = std::str::from_utf8(output.stdout.as_slice())
            .expect("stdout is not valid utf8")
            .trim()
            .to_string();
        assert_ne!(from_container_id, "");
        println!("from_container_id: {}", &from_container_id);
        thread::sleep(std::time::Duration::from_secs(5));
        wait_for_pg_ready(&from_container_id);
        //wait_for_log_msg(&from_container_id);
        let mut from_client = Client::connect(
            "postgres://postgres:password@localhost:5555/db",
            postgres::NoTls,
        )
        .expect("failed to connect to postgres");
        println!(
            "postgres thinks the data_directory is {}",
            pg_data_dir(&mut from_client)
        );
        let from_timescaledb_version = install_timescaledb_ext(&mut from_client);
        install_promscale_ext(&mut from_client, &from_version);
        if with_data {
            load_data(&from_container_id);
        }
        from_client
            .execute("checkpoint", &[])
            .expect("failed to checkpoint");
        stop_container(&from_container_id);
        from_timescaledb_version
    };

    set_permissions(&data_dir, permissions).expect("failed to chmod 0o777 on the data directory");

    // UPGRADE TO
    // create a container using the target image
    // map postgres' data dir to the same temp dir from before
    // update the promscale extension to the to_version
    // snapshot the database
    let upgraded_snapshot = {
        println!("UPGRADE TO");
        let child = Command::new("docker")
            .arg("run")
            .arg("-d")
            .args([
                "--mount",
                format!("type=bind,src={},dst=/scripts", script_dir).as_str(),
            ])
            .args([
                "--mount",
                format!("type=bind,src={},dst=/var/lib/postgresql/data", data_dir).as_str(),
            ])
            .args(["--env", "PGDATA=/var/lib/postgresql/data/data"])
            .args(["--env", "POSTGRES_HOST_AUTH_METHOD=trust"])
            .args(["--env", "POSTGRES_DB=db"])
            .args(["--env", "POSTGRES_USER=postgres"])
            .args(["--env", "POSTGRES_PASSWORD=password"])
            .args(["-p", "5556:5432"])
            .arg(to_image_uri)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("failed to create and run the docker container");
        let output = child
            .wait_with_output()
            .expect("failed to wait on docker run");
        assert!(
            output.status.success(),
            "docker run failed {}",
            std::str::from_utf8(output.stderr.as_slice()).expect("stderr is not valid utf8")
        );
        let to_container_id = std::str::from_utf8(output.stdout.as_slice())
            .expect("stdout is not valid utf8")
            .trim()
            .to_string();
        assert_ne!(to_container_id, "");
        println!("to_container_id: {}", &to_container_id);
        thread::sleep(std::time::Duration::from_secs(5));
        wait_for_pg_ready(&to_container_id);
        //wait_for_log_msg(&to_container_id);
        let mut to_client = Client::connect(
            "postgres://postgres:password@localhost:5556/db",
            postgres::NoTls,
        )
        .expect("failed to connect to postgres");
        println!(
            "postgres thinks the data_directory is {}",
            pg_data_dir(&mut to_client)
        );
        if from_timescaledb_version != to_timescaledb_version {
            assert!(from_timescaledb_version < to_timescaledb_version);
            println!(
                "upgrading from timescaledb {} to {}",
                from_timescaledb_version, to_timescaledb_version
            );
            update_extension(
                &to_container_id,
                "postgres",
                "db",
                "timescaledb",
                &to_timescaledb_version,
            );
        }
        update_extension(&to_container_id, "postgres", "db", "promscale", &to_version);
        let upgraded_snapshot = snapshot_db(
            &to_container_id,
            "db",
            "postgres",
            working_dir
                .join(format!(
                    "snapshot-{}-{}-{}.txt",
                    from_version,
                    to_version,
                    if with_data { "with-data" } else { "no-data" }
                ))
                .as_path(),
        );
        stop_container(&to_container_id);
        upgraded_snapshot
    };

    let are_equal = are_snapshots_equal(baseline_snapshot, upgraded_snapshot);
    assert!(are_equal);
}

fn stop_container(container_id: &str) {
    let exit = Command::new("docker")
        .arg("stop")
        .arg(&container_id)
        .spawn()
        .unwrap()
        .wait()
        .unwrap();
    assert!(
        exit.success(),
        "failed to stop container {}: {}",
        &container_id,
        exit
    );
}

fn wait_for_log_msg(container_id: &str) {
    loop {
        let output = Command::new("docker")
            .arg("logs")
            .arg(&container_id)
            .output()
            .expect("failed to get container logs");
        assert!(output.status.success());
        let logs = std::str::from_utf8(output.stdout.as_slice()).expect("stdout is not valid utf8");
        if logs.contains("database system is ready to accept connections") {
            break;
        }
        println!("postgres is not ready yet");
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
}

fn wait_for_pg_ready(container_id: &str) {
    loop {
        let exit = Command::new("docker")
            .arg("exec")
            .arg(&container_id)
            .arg("pg_isready")
            .spawn()
            .unwrap()
            .wait()
            .unwrap();
        let exit_code = exit.code().unwrap();
        assert!(
            exit_code < 3,
            "failed to wait for postgresql to be ready: {}",
            exit
        );
        if exit_code == 2 {
            println!("postgres is not answering yet");
            std::thread::sleep(std::time::Duration::from_secs(1));
        }
        if exit_code == 0 {
            println!("postgres is ready!");
            break;
        }
    }
}

fn image_uri_from_flavor_pg_version(flavor: &str, pg_version: &str) -> String {
    if flavor == "ha" {
        // ha
        format!("timescale/timescaledb-ha:{}-latest", pg_version)
    } else {
        // alpine
        format!(
            "ghcr.io/timescale/dev_promscale_extension:master-ts2-{}",
            pg_version
        )
    }
}

fn pg_version_from_image_uri(to_image_uri: &String) -> &str {
    let re = Regex::new("pg[0-9]{2}").unwrap();
    let pg_version = re.find(&to_image_uri).unwrap().as_str();
    pg_version
}

fn name(from_version: &FromVersion, with_data: bool, flavor: &str, pg_version: &str) -> String {
    format!(
        "test-upgrade-from-{}-{}-{}-{}",
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
    )
}

/*
fn create_docker_volume(
    from_version: &FromVersion,
    with_data: bool,
    flavor: &str,
    pg_version: &str,
) -> String {
    let vol_name = format!(
        "vol-{}-{}-{}-{}",
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
    // see if a volume by this name already exists
    let output = Command::new("docker")
        .arg("volume")
        .arg("ls")
        .args(["--filter", format!("name={}", &vol_name).as_str()])
        .args(["--format", "{{.Name}}"])
        .output()
        .expect("docker volume ls failed");
    // if so, delete that volume
    if output.stdout == vol_name.as_bytes() {
        let exit = Command::new("docker")
            .arg("volume")
            .arg("rm")
            .arg(&vol_name)
            .spawn()
            .unwrap()
            .wait()
            .unwrap();
        assert!(
            exit.success(),
            "removin the docker volume {} failed: {}",
            vol_name,
            exit
        );
    }
    // create the volume
    let exit = Command::new("docker")
        .arg("volume")
        .arg("create")
        .arg(&vol_name)
        .spawn()
        .unwrap()
        .wait()
        .unwrap();
    assert!(
        exit.success(),
        "creating the docker volume {} failed: {}",
        vol_name,
        exit
    );
    vol_name
}
*/

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
fn psql_file(container_id: &str, db: &str, username: &str, path: &Path) {
    println!("executing psql script {}...", path.display());
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
fn load_data(container_id: &str) {
    psql_file(
        container_id,
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
    copy_out(&container_id, snapshot, path);
    normalize_snapshot(path)
}

/// Determines the first, last, and prior versions of the promscale extension available
fn available_extension_versions(client: &mut Client) -> (Version, Version, Version) {
    let result = client
        .query(
            r"select version 
                     from pg_available_extension_versions 
                     where name = 'promscale' 
                     and version not in ('0.1', '0.5.3') and version not like '0.5.3-%';",
            &[],
        )
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

/// Determines the major version of postgres running
//fn pg_major_version(client: &mut Client) -> PgVersion {
//    let result = client
//        .query(
//            "select setting::int / 10000 from pg_settings where name = 'server_version_num';",
//            &[],
//        )
//        .expect("failed to select server_version_num");
//    let pg_major_version: i32 = result
//        .first()
//        .expect("failed to get result from selecting server_version_num")
//        .get(0);
//    match pg_major_version {
//        14 => PgVersion::V14,
//        13 => PgVersion::V13,
//        12 => PgVersion::V12,
//        _ => panic!("unsupported postgres major version {}", pg_major_version),
//    }
//}

/// Determines the data directory of the postgres cluster
fn pg_data_dir(client: &mut Client) -> String {
    let result = client
        .query("show data_directory", &[])
        .expect("failed to select data_directory");
    let data_dir: String = result
        .first()
        .expect("failed to get result from selecting data_directory")
        .get(0);
    data_dir
}

/// Diffs the two snapshots.
/// Differences are printed to the console.
/// Returns a boolean. True indicates the two snapshots are identical
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

/// Installs the timescaledb extension
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

/// Installs the promscale extension at the specified version
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

fn update_extension(
    container_id: &str,
    username: &str,
    db: &str,
    extension: &str,
    version: &Version,
) {
    let exit = Command::new("docker")
        .arg("exec")
        .arg(&container_id)
        .arg("psql")
        .args(["-U", username])
        .args(["-d", db])
        .arg("-X") // the -X flag is important!! This prevents any .psqlrc commands from accidentally triggering the load of a previous TimescaleDB version on session startup.
        .arg("--no-password")
        .arg("--no-psqlrc")
        .arg("--no-readline")
        .arg("--echo-all")
        .args(["-v", "ON_ERROR_STOP=1"])
        .args([
            "-c",
            format!(
                "alter extension {} update to '{}';",
                extension,
                version.to_string()
            )
            .as_str(),
        ])
        .spawn()
        .unwrap()
        .wait()
        .unwrap();
    assert!(
        exit.success(),
        "updating {} to version {} failed: {}",
        extension,
        version.to_string(),
        exit
    );
}
