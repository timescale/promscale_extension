use crate::common::run_postgres;
use testcontainers::clients;

mod common;

#[test]
fn create_promscale_extension() {
    let _ = pretty_env_logger::try_init();

    let docker = clients::Cli::default();
    let node = run_postgres(&docker);

    let mut client = common::connect(&node);
    let result = client.simple_query("CREATE EXTENSION promscale;").unwrap();

    assert_eq!(result.len(), 1);
}

#[test]
#[ignore]
fn create_drop_promscale_extension() {
    let _ = pretty_env_logger::try_init();

    let docker = clients::Cli::default();
    let node = run_postgres(&docker);

    let mut client = common::connect(&node);
    let result = client.simple_query("CREATE EXTENSION promscale;").unwrap();
    assert_eq!(result.len(), 1);

    let result = client.simple_query("DROP EXTENSION promscale;").unwrap();

    assert_eq!(result.len(), 1);
}
