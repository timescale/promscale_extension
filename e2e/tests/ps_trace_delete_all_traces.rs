use test_common::PostgresContainerBlueprint;
use test_common::{new_test_container_instance, PostgresTestInstance};

#[test]
fn delete_all_traces_blocks_if_advisory_lock_already_taken() {
    let _ = pretty_env_logger::try_init();
    let pg_blueprint = PostgresContainerBlueprint::new();
    let test_pg_instance = new_test_container_instance(&pg_blueprint);
    let mut conn_one = test_pg_instance.connect();
    let mut conn_two = test_pg_instance.connect();

    let result = conn_one
        .simple_query("CREATE EXTENSION promscale;")
        .unwrap();
    assert_eq!(result.len(), 1);
    let result = conn_one
        .query("SELECT pg_advisory_lock(5585198506344173278);", &[])
        .unwrap();
    assert_eq!(result.len(), 1);

    // Set statement timeout low, because we expect the following query to block on the advisory lock
    let result = conn_two
        .simple_query("SET statement_timeout=1000;")
        .unwrap();
    assert_eq!(result.len(), 1);

    let result = conn_two.query("SELECT ps_trace.delete_all_traces();", &[]);

    assert!(result.is_err());
    let error = result.expect_err("expected error");
    assert_eq!(
        error.as_db_error().unwrap().message(),
        "canceling statement due to statement timeout"
    );
}
