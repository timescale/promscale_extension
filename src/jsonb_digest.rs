use pgx::*;

#[pg_schema]
mod _prom_ext {
    use crate::iterable_jsonb::*;
    use pgx::*;
    use sha2::{Digest, Sha512};

    /// A custom SHA512 based JSONB digest.
    ///
    /// Save for hash collisions, for any pair of `j1` and `j2` the statement
    /// `SELECT jsonb_digest(j1) = jsonb_digest(j2)`
    /// is true iff `j1 == j2` are _semantically_ equivalent.
    ///
    /// There is a couple of alternatives, unfortunately neither
    /// should be used in a UNIQUE index.
    ///
    /// `pg_catalog.sha512(json_value::text::bytea)` has two drawbacks:
    /// - There isn't enough control over `jsonb` -> `text` conversion.
    ///   Although, the existing implementation relies on the same mechanism
    ///   as [`jsonb_digest`] and should always keep object keys in the fixed
    ///   order, there's no way to explicitly set specifics of its behaviour
    ///   like indentation or white-space padding.
    /// - JSONB stores all numeric values in PostgreSQL `numeric` type.
    ///   It's not just precise, it accurately preserves trailing fractional zeroes.
    ///   In other words, values `1.01` and `1.010` will be represented differently,
    ///   despite being equal.
    ///
    /// There's also `jsonb_hash_extended` that addresses the shortcomings,
    /// described above. Unfortunately, it is limited to 64 bit: good enough
    /// for hash tables, probably a bad idea for a UNIQUE index. This
    /// implementation is largely based on `jsonb_hash_extended`.
    #[pg_extern(immutable, strict, parallel_safe)]
    pub fn jsonb_digest(jsonb: Jsonb) -> Vec<u8> {
        use Token::*;

        // Based on https://github.com/postgres/postgres/blob/27b77ecf9f4d5be211900eda54d8155ada50d696/src/include/utils/jsonb.h#L193
        // I'm making an assumption here, that object key order
        // should remain stable in the foreseeable future.
        //
        // Additionally, there's a test that checks that a hardcoded value didn't change.
        let mut hasher = Sha512::new();
        jsonb.tokens().enumerate().for_each(|(idx, token)| {
            hasher.update(idx.to_le_bytes());
            match token {
                // Scalars
                Null => hasher.update(0x01u8.to_le_bytes()),
                Bool(true) => hasher.update(0x02u8.to_le_bytes()),
                Bool(false) => hasher.update(0x03u8.to_le_bytes()),
                String(str) => {
                    hasher.update(0x04u8.to_le_bytes());
                    hasher.update(str.as_bytes())
                }
                Token::Numeric(numeric) => {
                    hasher.update(0x05u8.to_le_bytes());
                    hasher.update(numeric.to_str().as_bytes())
                }
                // Objects
                Key(str) => {
                    hasher.update(0x0Au8.to_le_bytes());
                    hasher.update(str.as_bytes())
                }
                BeginObject => hasher.update(0x0Bu8.to_le_bytes()),
                EndObject => hasher.update(0x0Cu8.to_le_bytes()),
                // Arrays
                BeginArray => hasher.update(0x0Du8.to_le_bytes()),
                EndArray => hasher.update(0x0Eu8.to_le_bytes()),
            }
        });

        Vec::from(hasher.finalize().as_slice())
    }
}
#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgx::*;
    use std::collections::HashSet;
    use std::iter::FromIterator;

    #[pg_test]
    fn test_jsonb_digest_simple_values() {
        assert!(Spi::get_one::<Vec<u8>>(r#" SELECT jsonb_digest(NULL) "#,).is_none());

        let inputs = vec![
            "{}",
            "[]",
            "1",
            "-1.01",
            "1.01",
            "[null]",
            "null",
            "true",
            "false",
            r#""""#,
            r#""x""#,
            r#"{"a": "b"}"#,
            r#"{"b": "a"}"#,
            r#"{"a": {}}"#,
            r#"{"a": {"b": {}}}"#,
            r#"[1, {}, [], {"a": [true, false]}]"#,
        ];
        let digests = inputs
            .iter()
            .map(|test_val| {
                let digest = Spi::get_one::<Vec<u8>>(
                    format!("SELECT jsonb_digest('{}'::jsonb)", test_val).as_str(),
                )
                .expect("SQL query failed");

                assert_eq!(digest.len(), 64);
                format!("{:?}", digest)
            })
            .collect::<Vec<String>>();

        // all hashes are unique
        let distinct_digests: HashSet<String> = HashSet::from_iter(digests.iter().cloned());
        assert_eq!(distinct_digests.len(), inputs.len());
    }

    #[pg_test]
    fn test_jsonb_digest_equal_values() {
        let inputs = vec![
            ("1.01", "1.010"),
            (r#"{"a": "b", "c": "d"}"#, r#"{"c": "d", "a": "b"}"#),
        ];

        inputs.into_iter().for_each(|(v1, v2)| {
            let [d1, d2] = [v1, v2]
                .map(|v| format!("SELECT jsonb_digest('{}'::jsonb)::text", v))
                .map(|q| Spi::get_one::<String>(q.as_str()).expect("SQL query failed"));
            assert_eq!(d1, d2);
        });
    }

    #[pg_test]
    fn test_jsonb_digest_big_value() {
        let digest = Spi::get_one::<String>(
            r#"
            SELECT jsonb_digest(gen.json)::text
			FROM (
                SELECT jsonb_object_agg(n::text, n) AS json
                FROM generate_series(1, 2000) AS gs (n)
			) AS gen
            "#,
        )
        .expect("SQL query failed");

        // The expected value is hardcoded intentionally: it's the only way for
        // us to notice if the function's behaviour suddenly changes.
        assert_eq!(
            digest,
            "\\xd83ab57e672b815fbd877547a29135fa8c8eb9d3dae0b05229e89d60b352fce19442504cf809733fee3ef26de90620af693f3c87a1425b63ad308504487ae093"
        );
    }

    #[pg_test]
    fn test_jsonb_digest_toasted_value() {
        Spi::run(
            r#"
            CREATE TABLE json_digest_test(j JSONB);
            INSERT INTO json_digest_test (j) 
            SELECT jsonb_object_agg(n::text, n)
            FROM generate_series(1, 20000) AS gs (n);
            "#,
        );
        let digest = Spi::get_one::<Vec<u8>>(
            r#"
            SELECT jsonb_digest(t.j)
			FROM json_digest_test AS t
            "#,
        )
        .expect("SQL query failed");

        assert_eq!(digest.len(), 64);
    }

    use proptest::prelude::*;
    use serde_json::{json, Value};

    #[pg_test]
    fn test_jsonb_digest_prop_based() {
        // Notice: it's advisable to increase the number of cases 10x when making changes
        proptest!(ProptestConfig::with_cases(1000), |(j1 in arb_json(), j2 in arb_json())|{
            let (cmp, d1, d2) = jsonb_digest_cmp_json_run(j1, j2);
            if cmp { prop_assert_eq!(d1, d2) }
            else { prop_assert_ne!(d1, d2) }
        })
    }

    fn jsonb_digest_cmp_json_run(j1: Value, j2: Value) -> (bool, String, String) {
        let (cmp, d1, d2) = Spi::get_three_with_args::<bool, String, String>(
            r#"
            SELECT (j1 = j2), jsonb_digest(j1)::text, jsonb_digest(j2)::text
            FROM (SELECT $1::JSONB AS j1, $2::JSONB AS j2) AS jsons;
            "#,
            vec![j1, j2]
                .into_iter()
                .map(|json| (PgBuiltInOids::JSONBOID.oid(), pgx::JsonB(json).into_datum()))
                .collect(),
        );
        (cmp.unwrap(), d1.unwrap(), d2.unwrap())
    }

    fn arb_json() -> impl Strategy<Value = serde_json::Value> {
        let leaf = prop_oneof![
            Just(Value::Null),
            any::<bool>().prop_map(Value::Bool),
            any::<f64>().prop_map(|v| json!(v)),
            "[\\w\\s]*".prop_map(Value::String),
        ];
        let expected_max_collection_size = 10u32;
        let sz_range = 0..expected_max_collection_size as usize;
        leaf.prop_recursive(
            8,   // levels deep
            256, // Shoot for maximum size of 256 nodes
            expected_max_collection_size,
            move |inner| {
                prop_oneof![
                    // Take the inner strategy and make the two recursive cases.
                    prop::collection::vec(inner.clone(), sz_range.clone()).prop_map(Value::Array),
                    prop::collection::hash_map("\\w+", inner, sz_range.clone())
                        .prop_map(|kvs| Value::Object(serde_json::Map::from_iter(kvs.into_iter()))),
                ]
            },
        )
    }
}
