use std::{env, rc::Rc};

pub mod postgres_container;
pub use postgres_container::{PostgresContainer, PostgresContainerBlueprint};

mod test_container_instance;
pub use test_container_instance::TestContainerInstance;

mod local_postgres_instance;
pub use local_postgres_instance::LocalPostgresInstance;

mod postgres_test_connection;
pub use postgres_test_connection::PostgresTestConnection;

/// This trait provides an interface sufficient for the
/// majority of our tests and should be the first choice.
///
/// That being said, if your test requires a lower
/// level access to a test container [`postgres_container`]
/// is another option.
pub trait PostgresTestInstance {
    fn connect<'pg_inst>(&'pg_inst self) -> PostgresTestConnection<'pg_inst>;
    fn exec_sql_script(&self, script_path: &str) -> String;
}

/// Creates an instance of [`PostgresTestInstance`] that
/// can be backed either by a test container configured
/// according to the provided [`PostgresContainerBlueprint`]
/// or by a local PostgreSQL database connection.
///
/// The behaviour is controlled by the number of environment
/// variables:
/// - `USE_DOCKER` determines which backend to use
/// - `TS_DOCKER_IMAGE` determines the image to be used by the test container backend
/// - `POSTGRES_URL` or a combination of
///     `POSTGRES_USER`, `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`
///     are used by the local database connection backend.
pub fn new_test_instance_from_env<'h>(
    pg_blueprint: &'h PostgresContainerBlueprint,
) -> Rc<dyn PostgresTestInstance + 'h> {
    let use_docker = env::var("USE_DOCKER")
        .map(|val| val.to_ascii_lowercase() == "true")
        .unwrap_or(false);

    if use_docker {
        Rc::new(TestContainerInstance::fresh_instance(pg_blueprint))
    } else {
        Rc::new(LocalPostgresInstance::temporary_local_db())
    }
}

/// Creates an instance of [`PostgresTestInstance`] that
/// is guaranteed to be backed by a test container configured
/// according to the provided [`PostgresContainerBlueprint`].
///
/// - `TS_DOCKER_IMAGE` determines the image to be used.
pub fn new_test_container_instance<'h>(
    pg_blueprint: &'h PostgresContainerBlueprint,
) -> TestContainerInstance<'h> {
    TestContainerInstance::fresh_instance(pg_blueprint)
}
