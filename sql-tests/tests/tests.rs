use insta::assert_snapshot;
use std::{env, sync::{Mutex, Once}, mem::MaybeUninit};
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

#[test_resources("testdata/*.sql")]
fn sql_tests(resource: &str) {
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
    }

    let query_result = test_pg_instance.exec_sql_script(resource);
    assert_snapshot!(resource, query_result);
}
