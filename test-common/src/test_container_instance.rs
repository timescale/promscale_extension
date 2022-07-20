use std::process::{Command, Stdio};
use std::str::from_utf8;

use super::postgres_container::*;
use super::*;

pub struct TestContainerInstance<'h> {
    pg_blueprint: &'h PostgresContainerBlueprint,
    pub container: PostgresContainer<'h>,
}

impl<'pg_inst> TestContainerInstance<'pg_inst> {
    pub(crate) fn fresh_instance(pg_blueprint: &'pg_inst PostgresContainerBlueprint) -> Self {
        let container = pg_blueprint.run();
        TestContainerInstance {
            pg_blueprint: pg_blueprint,
            container: container,
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
