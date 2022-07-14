use postgres::Client;
use std::collections::HashMap;
use std::env;
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::str::from_utf8;
use testcontainers::clients;
use testcontainers::clients::Cli;
use testcontainers::core::WaitFor;
use testcontainers::images::generic::GenericImage;
use testcontainers::{images, Container};

/// A docker container running Postgres
pub type PostgresContainer<'d> = Container<'d, GenericImage>;

#[allow(dead_code)]
#[derive(Debug)]
enum ImageOrigin {
    Local,
    Latest,
    Master,
}

#[allow(dead_code)]
#[derive(Debug)]
enum PgVersion {
    V14,
    V13,
    V12,
}

fn postgres_image_uri(origin: ImageOrigin, version: PgVersion) -> String {
    let prefix = match origin {
        ImageOrigin::Local => "local/dev_promscale_extension:head-ts2-",
        ImageOrigin::Latest => "timescaledev/promscale-extension:latest-ts2.7.0-",
        ImageOrigin::Master => "ghcr.io/timescale/dev_promscale_extension:master-ts2-",
    };
    let version = match version {
        PgVersion::V12 => "pg12",
        PgVersion::V13 => "pg13",
        PgVersion::V14 => "pg14",
    };
    format!("{}{}", prefix, version)
}

#[derive(Debug, Clone)]
pub struct PostgresTestHarness {
    pub docker: Rc<Cli>,
    image_uri: String,
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
    pub fn default_image_uri() -> String {
        env::var("TS_DOCKER_IMAGE").unwrap_or_else(|_| {
            String::from(postgres_image_uri(ImageOrigin::Local, PgVersion::V14))
        })
    }

    fn init_docker() -> Cli {
        clients::Cli::default()
    }

    fn prepare_image(&self) -> GenericImage {
        let img_uri = self.image_uri();
        let (img_name, tag) = img_uri
            .rsplit_once(":")
            .unwrap_or_else(|| (img_uri, "latest"));

        images::generic::GenericImage::new(img_name, tag).with_wait_for(WaitFor::message_on_stderr(
            "database system is ready to accept connections",
        ))
    }

    pub fn new() -> Self {
        Self {
            docker: Rc::new(Self::init_docker()),
            image_uri: PostgresTestHarness::default_image_uri(),
            volumes: HashMap::default(),
            env_vars: HashMap::default(),
        }
        .with_db(Self::DB)
        .with_user(Self::USER)
        .with_password(Self::PASSWORD)
        .with_env_var("POSTGRES_HOST_AUTH_METHOD", "trust")
    }

    pub fn with_image_uri(mut self, image_uri: String) -> Self {
        self.image_uri = image_uri;
        self
    }

    pub fn image_uri(&self) -> &str {
        self.image_uri.as_str()
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
        let mut img = self.prepare_image();

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
        node.get_host_port_ipv4(5432),
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
