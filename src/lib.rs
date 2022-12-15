use pgx::pg_sys::AsPgCStr;
use pgx::*;

mod aggregate_utils;
mod aggregates;
mod iterable_jsonb;
mod jsonb_digest;
mod palloc;
mod pg_imports;
mod raw;
mod regex;
mod schema;
mod support;
mod type_builder;
mod util;

pg_module_magic!();

/// A helper function for building [`pgx::PgList`] out of
/// iterable collection of `str`.
///
/// For safety reasons it p-allocates and copies its arguemnts
/// every time. Which is OK for our current once-per-query usage,
/// but don't attempt it on per-row basis.
pub fn build_pg_list_of_cstrings<'a, I>(parts: I) -> PgList<pg_imports::PgString>
where
    I: IntoIterator<Item = &'a str>,
{
    let mut res = PgList::new();
    for p in parts {
        res.push(unsafe { pg_sys::makeString(p.as_pg_cstr() as _) });
    }
    res
}

#[cfg(test)]
#[pg_schema]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {
        // perform one-off initialization when the pg_test framework starts
    }

    pub fn postgresql_conf_options() -> Vec<&'static str> {
        // return any postgresql.conf settings that are required for your tests
        vec!["search_path = 'public, _prom_ext, ps_trace, _ps_trace'"]
    }
}
