use similar_asserts::assert_str_eq;
use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use testcontainers::clients::Cli;
use testcontainers::images::generic::{GenericImage, WaitFor};
use testcontainers::{clients, Container};
use testcontainers::{images, Docker};

fn run_postgres<'a>(docker: &'a Cli, db: &str, username: &str) -> Container<'a, Cli, GenericImage> {
    //let docker_image = env::var("TS_DOCKER_IMAGE").unwrap_or_else(|_| {
    //    String::from("ghcr.io/timescale/dev_promscale_extension:develop-ts2-pg14")
    //});
    // todo: hardcoded for now. fix when the extension is installed in public schema instead of _prom_ext
    let docker_image = "ghcr.io/timescale/dev_promscale_extension:jg-sec-audit-prom-ext-ts2-pg14";

    let src = concat!(env!("CARGO_MANIFEST_DIR"), "/scripts");
    let dest = "/scripts";

    let generic_postgres = images::generic::GenericImage::new(docker_image)
        .with_wait_for(WaitFor::message_on_stderr(
            "database system is ready to accept connections",
        ))
        .with_env_var("POSTGRES_DB", db)
        .with_env_var("POSTGRES_USER", username)
        .with_env_var("POSTGRES_HOST_AUTH_METHOD", "trust")
        .with_env_var("POSTGRES_PASSWORD", "password")
        .with_volume(src, dest);

    docker.run(generic_postgres)
}

fn psql_script(container: &Container<Cli, GenericImage>, db: &str, username: &str, path: &str) {
    println!("executing psql script {}...", path);
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
        .args(["-f", path])
        .spawn()
        .unwrap()
        .wait()
        .unwrap();
    assert!(
        exit.success(),
        "executing psql script {} failed: {}",
        path,
        exit
    );
}

fn psql_cmd(container: &Container<Cli, GenericImage>, db: &str, username: &str, cmd: &str) {
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

fn copy_in(container: &Container<Cli, GenericImage>, src: &PathBuf, dest: &PathBuf) {
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

fn copy_out(container: &Container<Cli, GenericImage>, src: &PathBuf, dest: &PathBuf) {
    if dest.exists() {
        fs::remove_file(dest.clone()).expect("failed to remove existing dest file");
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

fn snapshot_db(container: &Container<Cli, GenericImage>, db: &str, username: &str) -> String {
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
        .args(["-v", "ON_ERROR_STOP=1"])
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
    let dest = env::temp_dir().join(format!("snapshot-{}.txt", db));
    copy_out(container, &src, &dest);
    println!("database snapshot at: {}", dest.display());
    fs::read_to_string(dest.as_path()).unwrap()
}

fn dump_db(container: &Container<Cli, GenericImage>, db: &str, username: &str) -> PathBuf {
    let exit = Command::new("docker")
        .arg("exec")
        .arg(container.id())
        .arg("pg_dump")
        .args(["-U", username])
        .args(["-d", db])
        .arg("-v")
        .args(["-F", "p"])
        .args(["-T", "_prom_catalog.\"default\""]) // todo: undecided atm
        .args(["-T", "_prom_catalog.ids_epoch"]) // todo: Mat to look at
        .args(["-T", "_prom_catalog.remote_commands"]) // todo: set seq to start at 1000, only dump records >= 1000
        .args(["-T", "_ps_catalog.migration"]) // todo: should NOT be a config table. must restore at the same version at which we dumped
        .args(["-T", "_ps_catalog.promscale_instance_information"]) // todo: should NOT be a config table
        .args(["-T", "_ps_trace.tag_key"]) // todo: only dump records >= 1000
        .args(["-T", "public.prom_installation_info"]) // todo: ???
        .args(["-N", "_timescaledb_internal"])
        .args(["-N", "_timescaledb_cache"])
        .args(["-N", "_timescaledb_catalog"])
        .args(["-N", "_timescaledb_config"])
        .args(["-N", "_timescaledb_internal"])
        .args(["-N", "timescaledb_experimental"])
        .args(["-N", "timescaledb_information"])
        .args(["-f", "/tmp/dump.sql"])
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

    let src = PathBuf::from("/tmp/dump.sql");
    let dest = env::temp_dir().join(format!("dump-{}.sql", db));
    copy_out(container, &src, &dest);
    dest
}

fn restore_db(container: &Container<Cli, GenericImage>, db: &str, username: &str, path: PathBuf) {
    copy_in(container, &path, &PathBuf::from("/tmp/dump.sql"));
    psql_script(container, db, username, "/tmp/dump.sql");
}

#[test]
fn dump_restore_test() {
    let docker = clients::Cli::default();

    let container = run_postgres(&docker, "db0", "postgres");
    psql_script(&container, "db0", "postgres", "/scripts/init.sql");
    psql_cmd(
        &container,
        "db0",
        "postgres",
        "create user jack; grant prom_admin, postgres to jack;", // todo: jack should not need postgres role
    );
    let snapshot0 = snapshot_db(&container, "db0", "jack");
    let dump = dump_db(&container, "db0", "postgres"); // todo: dump using jack user
    container.stop();
    container.rm();

    println!("dump file at {}", dump.display());

    let container = run_postgres(&docker, "db1", "postgres");
    psql_cmd(
        &container,
        "db1",
        "postgres",
        "create user jill; grant all on database db1 to jill; grant postgres to jill;", // todo: jill should not need postgres role
    );
    psql_cmd(
        &container,
        "db1",
        "postgres", // todo: use jill for this
        "create extension if not exists timescaledb; create extension if not exists promscale; select public.timescaledb_pre_restore();"
    );
    restore_db(&container, "db1", "postgres", dump);
    psql_cmd(
        &container,
        "db1",
        "postgres", // todo: use jill for this
        "select public.timescaledb_post_restore();",
    );
    psql_cmd(&container, "db1", "postgres", "grant prom_admin to jill;");
    let snapshot1 = snapshot_db(&container, "db1", "jill");
    container.stop();
    container.rm();

    assert_str_eq!(snapshot0, snapshot1);
}
