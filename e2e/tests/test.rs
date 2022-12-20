use log::info;
use test_common::*;

#[test]
fn create_drop_promscale_extension() {
    let _ = pretty_env_logger::try_init();
    let pg_blueprint = PostgresContainerBlueprint::new();
    let test_pg_instance = new_test_container_instance(&pg_blueprint);
    let mut test_conn = test_pg_instance.connect();

    let result = test_conn
        .simple_query("CREATE EXTENSION promscale;")
        .unwrap();
    assert_eq!(result.len(), 1);

    let result = test_conn
        .simple_query("DROP EXTENSION promscale CASCADE;")
        .unwrap();

    assert_eq!(result.len(), 1);
}

#[test]
fn upgrade_promscale_extension_all_versions() {
    let _ = pretty_env_logger::try_init();
    let pg_blueprint = PostgresContainerBlueprint::new();
    let test_pg_instance = new_test_container_instance(&pg_blueprint);
    let mut test_conn = test_pg_instance.connect();
    // This query gets all possible upgrade paths for the extension. An upgrade
    // path looks like: "0.1.0--0.2.0--0.2.1--0.3.0".
    let path_rows = test_conn
        .query(r#"
            SELECT path
            FROM pg_extension_update_paths('promscale')
            WHERE
                path IS NOT NULL
                -- We want to skip all versions before 0.5.0 because they can't be installed directly
                AND NOT (
                    split_part(source, '.', 1)::INT = 0
                    AND
                    split_part(source, '.', 2)::INT < 5
                )
                -- When running on PG15 skip all versions before 0.8.0 because they don't exist for PG15
                AND NOT (
                    current_setting('server_version_num')::integer >= 150000
                    AND
                    split_part(source, '.', 1)::INT = 0
                    AND
                    split_part(source, '.', 2)::INT < 8
                )
                AND source IN (SELECT version FROM pg_available_extension_versions WHERE name = 'promscale')
            "#, &[])
        .unwrap();

    let version_paths: Vec<Vec<String>> = path_rows
        .iter()
        .map(|r| {
            let path = r.get::<&str, &str>("path");
            // Split string "0.1.0--0.2.0" into vec ["0.1.0", "0.2.0"].
            path.split("--")
                .map(str::to_string)
                .collect::<Vec<String>>()
        })
        .collect();

    for version_path in version_paths {
        let mut prev_version: Option<String> = None;
        for version in version_path {
            match prev_version {
                None => {
                    info!("Creating extension at version {}", version);
                    let res = test_conn.query(
                        &format!("CREATE EXTENSION promscale VERSION '{}'", version),
                        &[],
                    );
                    assert!(
                        res.is_ok(),
                        "cannot create extension at version {}: {}",
                        version,
                        res.unwrap_err()
                    );
                }
                Some(prev_version) => {
                    info!(
                        "Upgrading extension from version {} to {}",
                        prev_version, version
                    );
                    let res = test_conn.query(
                        &format!("ALTER EXTENSION promscale UPDATE TO '{}'", version),
                        &[],
                    );
                    assert!(
                        res.is_ok(),
                        "cannot upgrade extension from version {} to {}: {}",
                        prev_version,
                        version,
                        res.unwrap_err(),
                    );
                }
            }
            prev_version = Some(version);
        }
        let res = test_conn.query("DROP EXTENSION promscale CASCADE;", &[]);
        assert!(res.is_ok(), "cannot drop extension: {}", res.unwrap_err());
    }
}
