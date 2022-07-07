use insta::assert_snapshot;
use std::env;
use test_common::{exec_sql_script, run_postgres_with_data};
use test_generator::test_resources;

const TESTDATA: &'static str = concat!(env!("CARGO_MANIFEST_DIR"), "/testdata");

#[test_resources("testdata/*.sql")]
fn golden_test(resource: &str) {
    let docker = test_common::init_docker();
    let node = run_postgres_with_data(&docker, TESTDATA);
    let query_result = exec_sql_script(&node, resource);

    assert_snapshot!(resource, query_result);
}
