#[test]
fn create_drop_promscale_extension() {
    let _ = pretty_env_logger::try_init();

    let pg_harness = test_common::PostgresTestHarness::new();
    let node = pg_harness.run();

    let mut client = test_common::connect(&pg_harness, &node);
    let result = client.simple_query("CREATE EXTENSION promscale;").unwrap();
    assert_eq!(result.len(), 1);

    let result = client
        .simple_query("DROP EXTENSION promscale CASCADE;")
        .unwrap();

    assert_eq!(result.len(), 1);
}

#[test]
fn upgrade_promscale_extension_0_5_0_to_0_5_1() {
    let _ = pretty_env_logger::try_init();

    let pg_harness = test_common::PostgresTestHarness::new();
    let node = pg_harness.run();

    let mut client = test_common::connect(&pg_harness, &node);
    let result = client
        .simple_query("CREATE EXTENSION promscale VERSION '0.5.0';")
        .unwrap();
    assert_eq!(result.len(), 1);

    let result = client
        .simple_query("ALTER EXTENSION promscale UPDATE TO '0.5.1';")
        .unwrap();
    assert_eq!(result.len(), 1);
}
