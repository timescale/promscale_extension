use log::{error, info};
use postgres::Client;
use std::fmt::{Display, Formatter};
use testcontainers::images::generic::GenericImage;
use testcontainers::Container;

mod blueprint;

/// A docker container running Postgres
pub type PostgresContainer<'d> = Container<'d, GenericImage>;

pub use blueprint::PostgresContainerBlueprint;

#[allow(dead_code)]
#[derive(Debug)]
pub enum ImageOrigin {
    Local,
    Latest,
    Master,
}

#[allow(dead_code)]
#[derive(Debug)]
pub enum PgVersion {
    V14,
    V13,
    V12,
}

impl TryFrom<&str> for PgVersion {
    type Error = String;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "14" => Ok(PgVersion::V14),
            "13" => Ok(PgVersion::V13),
            "12" => Ok(PgVersion::V12),
            _ => Err(format!("Unknown postgres version {}", value)),
        }
    }
}

impl Display for PgVersion {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            PgVersion::V14 => write!(f, "14"),
            PgVersion::V13 => write!(f, "13"),
            PgVersion::V12 => write!(f, "12"),
        }
    }
}

pub fn postgres_image_uri(origin: ImageOrigin, version: PgVersion) -> String {
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

pub fn connect(pg_blueprint: &PostgresContainerBlueprint, container: &PostgresContainer) -> Client {
    let connection_string = format!(
        "postgres://{}:{}@localhost:{}/{}",
        pg_blueprint.user(),
        pg_blueprint.password(),
        container.get_host_port_ipv4(5432),
        pg_blueprint.db()
    );
    retry(|| Client::connect(&connection_string, postgres::NoTls), 3).unwrap()
}

fn retry<T, E, F>(operation: F, count: i32) -> Result<T, E>
where
    E: Display,
    F: Fn() -> Result<T, E>,
{
    let result: Result<T, E> = operation();
    match result {
        Ok(result) => Ok(result),
        Err(error) => {
            if count == 1 {
                error!("encountered error '{}', no more retries", error);
                return Err(error);
            }
            info!("encountered error '{}', will retry", error);
            return retry(operation, count - 1);
        }
    }
}
