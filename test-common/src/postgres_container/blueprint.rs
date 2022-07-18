use std::collections::HashMap;
use std::env;
use std::rc::Rc;
use testcontainers::clients;
use testcontainers::clients::Cli;
use testcontainers::core::WaitFor;
use testcontainers::images;
use testcontainers::images::generic::GenericImage;

use super::*;

#[derive(Debug, Clone)]
pub struct PostgresContainerBlueprint {
    pub docker: Rc<Cli>,
    image_uri: String,
    volumes: HashMap<String, String>,
    env_vars: HashMap<String, String>,
}

impl PostgresContainerBlueprint {
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
            image_uri: PostgresContainerBlueprint::default_image_uri(),
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
