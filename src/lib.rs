use pgx::*;

mod aggregate_utils;
mod aggregates;
mod iterable_jsonb;
mod jsonb_digest;
mod palloc;
mod raw;
mod schema;
mod support;
mod type_builder;
mod util;

pg_module_magic!();

#[cfg(test)]
#[pg_schema]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {
        // perform one-off initialization when the pg_test framework starts
    }

    pub fn postgresql_conf_options() -> Vec<&'static str> {
        // return any postgresql.conf settings that are required for your tests
        vec!["search_path = 'public, _prom_ext'"]
    }
}
