use crate::common::{exec_sql_script, run_postgres};
use insta::assert_snapshot;
use std::env;
use test_generator::test_resources;
use testcontainers::clients;

mod common;

#[test_resources("testdata/*.sql")]
fn golden_test(resource: &str) {
    let docker = clients::Cli::default();
    let node = run_postgres(&docker);
    let query_result = exec_sql_script(&node, resource);

    assert_snapshot!(resource, query_result);
}
