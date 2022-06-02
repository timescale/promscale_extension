use postgres::Client;
use std::env;
use std::process::{Command, Stdio};
use std::str::from_utf8;
use testcontainers::clients::Cli;
use testcontainers::images::generic::{GenericImage, WaitFor};
use testcontainers::{images, Container, Docker};

pub const DB: &str = "postgres-db-test";
pub const USER: &str = "postgres-user-test";
pub const PASSWORD: &str = "postgres-password-test";

pub fn run_postgres(client: &Cli) -> Container<Cli, GenericImage> {
    let docker_image = env::var("TS_DOCKER_IMAGE").unwrap_or(String::from(
        "ghcr.io/timescale/dev_promscale_extension:master-ts2-pg14",
    ));

    let src = concat!(env!("CARGO_MANIFEST_DIR"), "/testdata");
    let dest = "/testdata";

    let generic_postgres = images::generic::GenericImage::new(docker_image)
        .with_wait_for(WaitFor::message_on_stderr(
            "database system is ready to accept connections",
        ))
        .with_env_var("POSTGRES_DB", DB)
        .with_env_var("POSTGRES_USER", USER)
        .with_env_var("POSTGRES_PASSWORD", PASSWORD)
        .with_volume(src, dest);

    client.run(generic_postgres)
}

#[allow(dead_code)]
pub fn connect(node: &Container<Cli, GenericImage>) -> Client {
    let connection_string = &format!(
        "postgres://{}:{}@localhost:{}/{}",
        USER,
        PASSWORD,
        node.get_host_port(5432).unwrap(),
        DB
    );

    Client::connect(connection_string, postgres::NoTls).unwrap()
}

#[allow(dead_code)]
pub fn exec_sql_script(node: &Container<Cli, GenericImage>, script_path: &str) -> String {
    let id = node.id();
    let abs_script_path = "/".to_owned() + script_path;
    let output = Command::new("docker")
        .arg("exec")
        .arg(id)
        .arg("bash")
        .arg("-c")
        .arg(format!(
            "psql -U {} -d {} -f {} 2>&1",
            USER, DB, abs_script_path
        ))
        .stdout(Stdio::piped())
        .spawn()
        .unwrap()
        .wait_with_output()
        .unwrap();
    from_utf8(&output.stdout).unwrap().to_string()
}
