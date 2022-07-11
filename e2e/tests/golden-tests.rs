use insta::assert_snapshot;
use std::env;
use test_common::exec_sql_script;
use test_generator::test_resources;

const TESTDATA: &'static str = concat!(env!("CARGO_MANIFEST_DIR"), "/testdata");

#[test_resources("testdata/*.sql")]
fn golden_test(resource: &str) {
    let pg_harness = test_common::PostgresTestHarness::new().with_testdata(TESTDATA);
    let node = pg_harness.run();
    let query_result = exec_sql_script(&pg_harness, &node, resource);

    assert_snapshot!(resource, query_result);
}
