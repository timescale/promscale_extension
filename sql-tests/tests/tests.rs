use insta::assert_snapshot;
use std::env;
use test_common::*;
use test_generator::test_resources;

const TESTDATA: &'static str = concat!(env!("CARGO_MANIFEST_DIR"), "/testdata");

#[test_resources("testdata/*.sql")]
fn sql_tests(resource: &str) {
    let pg_blueprint = PostgresContainerBlueprint::new().with_testdata(TESTDATA);
    let test_pg_instance = TestContainerInstance::fresh_instance(&pg_blueprint);
    let query_result = test_pg_instance.exec_sql_script(resource);

    assert_snapshot!(resource, query_result);
}
