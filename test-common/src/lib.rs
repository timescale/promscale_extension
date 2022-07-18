use postgres::config::Host;
use postgres::{Client, Config};
use rand::Rng;
use std::env;
use std::os::unix::prelude::FromRawFd;
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::str::from_utf8;

pub mod postgres_container;
pub use postgres_container::{PostgresContainer, PostgresContainerBlueprint};

pub struct PostgresTestConnection<'pg_inst> {
    pub client: Client,
    // a phantom to hold onto parent's lifetime
    // to prevent premature database shutdown.
    _parent: &'pg_inst dyn PostgresTestInstance,
}

pub trait PostgresTestInstance {
    fn connect<'pg_inst>(&'pg_inst self) -> PostgresTestConnection<'pg_inst>;
    fn exec_sql_script(&self, script_path: &str) -> String;
}

pub struct TestContainerInstance<'h> {
    pg_blueprint: &'h PostgresContainerBlueprint,
    pub container: PostgresContainer<'h>,
}

impl<'pg_inst> TestContainerInstance<'pg_inst> {
    pub fn fresh_instance(pg_blueprint: &'pg_inst PostgresContainerBlueprint) -> Self {
        TestContainerInstance {
            pg_blueprint: pg_blueprint,
            container: pg_blueprint.run(),
        }
    }
}

impl<'h> PostgresTestInstance for TestContainerInstance<'h> {
    fn connect<'pg_inst>(&'pg_inst self) -> PostgresTestConnection<'pg_inst> {
        PostgresTestConnection {
            client: postgres_container::connect(self.pg_blueprint, &self.container),
            _parent: self,
        }
    }

    fn exec_sql_script(&self, script_path: &str) -> String {
        let id = self.container.id();
        let abs_script_path = "/".to_owned() + script_path;
        let output = Command::new("docker")
            .arg("exec")
            .arg(id)
            .arg("bash")
            .arg("-c")
            .arg(format!(
                "psql -U {} -d {} -f {} 2>&1",
                self.pg_blueprint.user(),
                self.pg_blueprint.db(),
                abs_script_path
            ))
            .stdout(Stdio::piped())
            .spawn()
            .unwrap()
            .wait_with_output()
            .unwrap();
        from_utf8(&output.stdout).unwrap().to_string()
    }
}

pub struct LocalPostgresInstance {
    db_name: String,
    admin_conn: Client,
}

impl LocalPostgresInstance {
    fn generate_random_db_name() -> String {
        let mut rng = rand::thread_rng();
        let n2: u16 = rng.gen();
        format!("test_database_{}", n2)
    }

    fn local_config_from_env(database: Option<&str>) -> Config {
        env::var("POSTGRES_URL")
            .map(|url| {
                let mut config = url.parse::<Config>().unwrap();
                database.map(|db| config.dbname(db));
                config
            })
            .unwrap_or_else(|_err| {
                let connection_string = &format!(
                    "postgres://{}@{}:{}/{}",
                    env::var("POSTGRES_USER").unwrap_or(String::from("postgres")),
                    env::var("POSTGRES_HOST").unwrap_or(String::from("localhost")),
                    env::var("POSTGRES_PORT").unwrap_or(String::from("5432")),
                    database
                        .map(|db_str| String::from(db_str))
                        .unwrap_or_else(
                            || env::var("POSTGRES_DB").unwrap_or(String::from("postgres"))
                        )
                );
                connection_string.parse::<Config>().unwrap()
            })
    }

    fn connect_local(database: Option<&str>) -> Client {
        let config = Self::local_config_from_env(database);
        config.connect(postgres::NoTls).unwrap()
    }

    pub fn temporary_local_db() -> Self {
        let db_name = Self::generate_random_db_name();
        let mut admin_conn = Self::connect_local(None);
        admin_conn
            .simple_query(format!("CREATE DATABASE {};", db_name).as_str())
            .unwrap();

        LocalPostgresInstance {
            db_name,
            admin_conn,
        }
    }
}

impl Drop for LocalPostgresInstance {
    fn drop(&mut self) {
        self.admin_conn
            .simple_query(format!("DROP DATABASE {};", self.db_name).as_str())
            .unwrap();
    }
}

impl PostgresTestInstance for LocalPostgresInstance {
    fn connect<'pg_inst>(&'pg_inst self) -> PostgresTestConnection<'pg_inst> {
        PostgresTestConnection {
            client: LocalPostgresInstance::connect_local(Some(&self.db_name)),
            _parent: self,
        }
    }

    fn exec_sql_script(&self, script_path: &str) -> String {
        let conf = Self::local_config_from_env(Some(&self.db_name));
        let mut cmd = Command::new("psql");

        conf.get_user().map(|u| cmd.arg("-U").arg(u));
        conf.get_hosts()
            .first()
            .and_then(|h| match h {
                Host::Tcp(hostname) => Some(hostname),
                _ => None,
            })
            .map(|h| cmd.arg("-h").arg(h));
        conf.get_ports()
            .first()
            .map(|p| cmd.arg("-p").arg(format!("{}", p)));
        conf.get_dbname().map(|db| cmd.arg("-d").arg(db));
        conf.get_password()
            .map(|pwd| cmd.env("PGPASSWORD", from_utf8(pwd).unwrap()));

        let output = cmd
            .arg("-f")
            .arg(script_path)
            .stdout(Stdio::piped())
            // safe because we are using STDOUT
            .stderr(unsafe { Stdio::from_raw_fd(1) })
            .spawn()
            .unwrap()
            .wait_with_output()
            .unwrap();
        from_utf8(&output.stdout).unwrap().to_string()
    }
}

impl PostgresTestConnection<'_> {
    pub fn in_docker_db<F>(f: F)
    where
        F: Fn(&mut PostgresTestConnection),
    {
        let pg_blueprint = PostgresContainerBlueprint::new();
        let pg_instance = TestContainerInstance::fresh_instance(&pg_blueprint);
        let mut conn = pg_instance.connect();
        f(&mut conn)
    }
}

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
