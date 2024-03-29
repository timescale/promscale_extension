use insta::assert_snapshot;
use pgtap_parse::parse_pgtap_result;
use std::{
    env,
    mem::MaybeUninit,
    sync::{Mutex, Once},
};
use test_common::*;
use test_generator::test_resources;

const TESTDATA: &'static str = concat!(env!("CARGO_MANIFEST_DIR"), "/testdata");

fn init_lock() -> &'static Mutex<()> {
    static mut SINGLETON: MaybeUninit<Mutex<()>> = MaybeUninit::uninit();
    static ONCE: Once = Once::new();

    unsafe {
        ONCE.call_once(|| {
            let singleton = Mutex::new(());
            SINGLETON.write(singleton);
        });

        SINGLETON.assume_init_ref()
    }
}

// TODO fix how test_resources works in nexted workspaces
#[test_resources("sql-tests/testdata/*.sql")]
fn sql_tests(full_resource: &str) {
    let pg_blueprint = PostgresContainerBlueprint::new().with_testdata(TESTDATA);
    let test_pg_instance = new_test_instance_from_env(&pg_blueprint);
    let mut init_conn = test_pg_instance.connect();
    // This lock prevents multiple callers from running
    // CREATE EXTENSION simultaneously. In case of
    // promscale_extension concurrent CREATE EXTENSION causes
    // issues when migration incremental/003-users.sql executes.
    {
        let _init_lock = init_lock().lock().unwrap();
        init_conn
            .simple_query("CREATE EXTENSION promscale;")
            .expect("Unable to create extension promscale.");

        init_conn
            .simple_query("SELECT 1;")
            .expect("Health-check query failed");
    }

    let resource = if let Some((_, rest)) = full_resource.split_once('/') {
        rest
    } else {
        full_resource
    };
    let query_result = test_pg_instance.exec_sql_script(resource);

    match parse_pgtap_result(&query_result) {
        Some(result) => {
            // Result parsed as pgtap output
            if result.executed_test_count != result.planned_test_count
                || result.success_count != result.planned_test_count
            {
                assert!(false, "{}", query_result);
            }
        }
        None => {
            // Result is not pgtap output, fall back to snapshot compare
            assert_snapshot!(resource, query_result)
        }
    }
}
