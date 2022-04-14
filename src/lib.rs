use pgx::*;

mod aggregate_utils;
mod aggregates;
mod iterable_jsonb;
mod jsonb_digest;
mod palloc;
mod pg_imports;
mod raw;
mod schema;
mod support;
mod type_builder;
mod util;

pg_module_magic!();

pub fn build_pg_list_of_strings<'a, I>(parts: I) -> PgList<pg_sys::Value>
where
    I: IntoIterator<Item = &'a str>,
{
    let mut res = PgList::new();
    for p in parts {
        let cstr = ::std::ffi::CString::new(p).unwrap().into_raw();
        res.push(unsafe { pg_sys::makeString(cstr) });
    }
    res
}

/// TODO: presently, we deliberate on how to structure SQL-only tests.
/// As soon as we agree on something these tests should be moved over.

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgx::*;
    use serde_json::json;
    use std::collections::HashSet;
    use std::iter::FromIterator;

    #[pg_test]
    fn test_very_large_values_in_put_tag() {
        let tag_id = Spi::get_one::<i64>(
            r#"
            SELECT put_tag('service.namespace', gen.kilobytes_of_garbage::jsonb, resource_tag_type())
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

    #[pg_test]
    fn test_put_tag_same_value() {
        let tag_ids: Vec<i64> = vec!["service.namespace", "faas.name"]
            .into_iter()
            .map(|key| {
                Spi::get_one_with_args::<i64>(
                    r#" SELECT put_tag($1, '"testvalue"', resource_tag_type()); "#,
                    vec![(PgBuiltInOids::TEXTOID.oid(), key.into_datum())],
                )
                .expect("SQL query failed")
            })
            .collect();

        // tag ids are distinct
        let distinct_digests: HashSet<i64> = HashSet::from_iter(tag_ids.iter().cloned());
        assert_eq!(distinct_digests.len(), tag_ids.len());
    }

    #[pg_test]
    fn test_put_tag_same_key() {
        let tag_ids: Vec<i64> = vec![1, 2]
            .into_iter()
            .map(|v| JsonB(json!({ "testvalue": v })))
            .map(|jsonb| {
                Spi::get_one_with_args::<i64>(
                    r#" SELECT put_tag('service.namespace', $1::text::jsonb, resource_tag_type()); "#,
                    vec![(PgBuiltInOids::JSONBOID.oid(), jsonb.into_datum())],
                )
                .expect("SQL query failed")
            })
            .collect();

        // tag ids are distinct
        let distinct_digests: HashSet<i64> = HashSet::from_iter(tag_ids.iter().cloned());
        assert_eq!(distinct_digests.len(), tag_ids.len());
    }

    #[pg_test]
    fn test_tag_funs() {
        let op_tag_id =
            Spi::get_one::<i64>(r#"SELECT put_operation('myservice', 'test', 'unspecified');"#)
                .expect("SQL query failed");

        let srvc_tag_id = Spi::get_one::<i64>(
            r#"SELECT put_tag('service.name', '"myservice"'::jsonb, resource_tag_type())"#,
        )
        .expect("SQL query failed");

        let op_tag_id_stored = Spi::get_one_with_args::<i64>(
            r#"
            SELECT id
            FROM _ps_trace.operation
            WHERE service_name_id = $1
            AND span_kind = 'unspecified'
            AND span_name = 'test';
            "#,
            vec![(PgBuiltInOids::INT8OID.oid(), srvc_tag_id.into_datum())],
        )
        .expect("SQL query failed");
        assert_eq!(op_tag_id, op_tag_id_stored);

        let host_tag_id = Spi::get_one::<i64>(
            r#"SELECT put_tag('host.name', '"foobar"'::jsonb, resource_tag_type())"#,
        )
        .expect("SQL query failed");

        let get_tag_res =
            Spi::get_one::<JsonB>(r#"SELECT get_tag_map(('{"host.name": "foobar", "service.name": "myservice"}')::jsonb)"#)
                .expect("SQL query failed");
        assert_eq!(
            get_tag_res.0,
            serde_json::json!({ "1": srvc_tag_id, "33": host_tag_id })
        );

        let eval_eq_res = Spi::get_one::<JsonB>(
            r#"SELECT _ps_trace.eval_equals(ROW('service.name', '"myservice"'::jsonb));"#,
        )
        .expect("SQL query failed");
        assert_eq!(eval_eq_res.0, serde_json::json!({ "1": srvc_tag_id }));
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
        vec!["search_path = 'public, _prom_ext, ps_trace'"]
    }
}
