use pgx::*;

mod aggregate_utils;
mod aggregates;
mod palloc;
mod raw;
mod schema;
mod support;
mod type_builder;
mod util;

pg_module_magic!();

/// TODO: presently, we deliberate on how to structure SQL-only tests.
/// As soon as we agree on something these tests should be moved over.

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgx::*;

    #[pg_test]
    fn test_very_large_values_in_put_tag() {
        let tag_id = Spi::get_one::<i64>(
            r#"
            SELECT put_tag('service.name', gen.kilobytes_of_garbage::jsonb, resource_tag_type())
			FROM (
				SELECT string_agg(n::text, '') AS kilobytes_of_garbage
				FROM generate_series(1, 2000) AS gs (n)
			) AS gen
            "#,
        )
        .expect("SQL query failed");

        let (res_id, res_val) = Spi::get_two_with_args::<i64, String>(
            r#"
                SELECT id, value::text
                FROM _ps_trace.tag 
                WHERE id = $1
                "#,
            vec![(PgBuiltInOids::INT8OID.oid(), tag_id.into_datum())],
        );

        assert_eq!(res_id, Some(tag_id));
        match res_val {
            Some(v) if v.len() > 2704 => {}
            _ => assert!(
                false,
                "tag value is shorter than btree's version 4 maximum row size for an index"
            ),
        };
    }
}

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
