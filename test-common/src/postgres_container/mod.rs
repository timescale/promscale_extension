use postgres::Client;
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

pub fn postgres_image_uri(origin: ImageOrigin, version: PgVersion) -> String {
    let prefix = match origin {
        ImageOrigin::Local => "local/dev_promscale_extension:head-ts2-",
        ImageOrigin::Latest => "timescaledev/promscale-extension:latest-ts2-",
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
    Client::connect(&connection_string, postgres::NoTls).unwrap()
}
