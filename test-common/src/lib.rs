use postgres::Client;
use std::collections::HashMap;
use std::env;
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::str::from_utf8;
use testcontainers::clients;
use testcontainers::clients::Cli;
use testcontainers::images::generic::{GenericImage, WaitFor};
use testcontainers::{images, Container, Docker};

/// A docker container running Postgres
pub type PostgresContainer<'d> = Container<'d, Cli, GenericImage>;

#[derive(Debug, Clone)]
pub struct PostgresTestHarness {
    pub docker: Rc<Cli>,
    volumes: HashMap<String, String>,
    env_vars: HashMap<String, String>,
}

impl PostgresTestHarness {
    const DB: &'static str = "postgres-db-test";
    const USER: &'static str = "postgres-user-test";
    const PASSWORD: &'static str = "postgres-password-test";

    /// Returns the name of the docker image to use for Postgres containers.
    /// If the `TS_DOCKER_IMAGE` environment variable is set, it will return that value.
    /// Otherwise, it returns a default image.
    pub fn postgres_image_uri() -> String {
        env::var("TS_DOCKER_IMAGE").unwrap_or_else(|_| {
            String::from("ghcr.io/timescale/dev_promscale_extension:master-ts2-pg14")
        })
    }

    fn init_docker() -> Cli {
        clients::Cli::default()
    }

    fn prepare_postgres_image() -> GenericImage {
        images::generic::GenericImage::new(Self::postgres_image_uri()).with_wait_for(
            WaitFor::message_on_stderr("database system is ready to accept connections"),
        )
    }

    pub fn new() -> Self {
        Self {
            docker: Rc::new(Self::init_docker()),
            volumes: HashMap::default(),
            env_vars: HashMap::default(),
        }
        .with_db(Self::DB)
        .with_user(Self::USER)
        .with_password(Self::PASSWORD)
        .with_env_var("POSTGRES_HOST_AUTH_METHOD", "trust")
    }

    pub fn with_volume<F: Into<String>, D: Into<String>>(mut self, from: F, dest: D) -> Self {
        self.volumes.insert(from.into(), dest.into());
        self
    }

    pub fn with_env_var<K: Into<String>, V: Into<String>>(mut self, k: K, v: V) -> Self {
        self.env_vars.insert(k.into(), v.into());
        self
    }

    pub fn with_db<T: Into<String>>(self, v: T) -> Self {
        self.with_env_var("POSTGRES_DB", v)
    }

    pub fn db(&self) -> &str {
        self.env_vars.get("POSTGRES_DB").unwrap().as_str()
    }

    pub fn with_user<T: Into<String>>(self, v: T) -> Self {
        self.with_env_var("POSTGRES_USER", v)
    }

    pub fn user(&self) -> &str {
        self.env_vars.get("POSTGRES_USER").unwrap().as_str()
    }

    pub fn with_password<T: Into<String>>(self, v: T) -> Self {
        self.with_env_var("POSTGRES_PASSWORD", v)
    }

    pub fn password(&self) -> &str {
        self.env_vars.get("POSTGRES_PASSWORD").unwrap().as_str()
    }

    pub fn with_testdata(self, src: &str) -> Self {
        self.with_volume(src, "/testdata")
    }

    pub fn run(&self) -> PostgresContainer {
        let mut img = Self::prepare_postgres_image();

        for (from, to) in self.volumes.iter() {
            img = img.with_volume(from, to);
        }
        for (k, v) in self.env_vars.iter() {
            img = img.with_env_var(k, v);
        }

        self.docker.run(img)
    }
}

pub fn connect(pg_harness: &PostgresTestHarness, node: &PostgresContainer) -> Client {
    let connection_string = &format!(
        "postgres://{}:{}@localhost:{}/{}",
        pg_harness.user(),
        pg_harness.password(),
        node.get_host_port(5432).unwrap(),
        pg_harness.db()
    );

    Client::connect(connection_string, postgres::NoTls).unwrap()
}

pub fn exec_sql_script(
    pg_harness: &PostgresTestHarness,
    node: &PostgresContainer,
    script_path: &str,
) -> String {
    let id = node.id();
    let abs_script_path = "/".to_owned() + script_path;
    let output = Command::new("docker")
        .arg("exec")
        .arg(id)
        .arg("bash")
        .arg("-c")
        .arg(format!(
            "psql -U {} -d {} -f {} 2>&1",
            pg_harness.user(),
            pg_harness.db(),
            abs_script_path
        ))
        .stdout(Stdio::piped())
        .spawn()
        .unwrap()
        .wait_with_output()
        .unwrap();
    from_utf8(&output.stdout).unwrap().to_string()
}
