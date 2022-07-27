use postgres::config::Host;
use postgres::{Client, Config};
use rand::Rng;
use std::env;
use std::process::{Command, Stdio};
use std::str::from_utf8;

use super::postgres_test_connection::PostgresTestConnection;
use super::PostgresTestInstance;

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

    pub(crate) fn temporary_local_db() -> Self {
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

        // a workaround to forward stderr to stdout
        // in the same way Docker backend does.
        let str_cmd = format!("{:?} 2>&1", cmd.arg("-f").arg(script_path));

        let output = Command::new("bash")
            .arg("-c")
            .arg(str_cmd)
            .stdout(Stdio::piped())
            .spawn()
            .unwrap()
            .wait_with_output()
            .unwrap();
        from_utf8(&output.stdout).unwrap().to_string()
    }
}
