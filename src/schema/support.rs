//! Here we redefine functions which are defined in `promscale`, attaching the
//! support function to them. It's undesirable to redefine those functions from
//! `promscale` because adding a support function requires superuser privileges.
//!
//! The original definition for these can found in the `pkg/migrations` of the
//! [promscale] project.
//!
//! [promscale]: https://www.github.com/timescale/promscale

use pgx::*;

extension_sql!(
    r#"
CREATE OR REPLACE FUNCTION @extschema@.label_find_key_equal(key_to_match label_key, pat pattern)
RETURNS matcher_positive
AS $func$
    SELECT COALESCE(array_agg(l.id), array[]::int[])::matcher_positive
    FROM label l
    WHERE l.key = key_to_match and l.value = pat
$func$
LANGUAGE SQL STABLE PARALLEL SAFE
SUPPORT @extschema@.rewrite_fn_call_to_subquery;

CREATE OR REPLACE FUNCTION @extschema@.label_find_key_not_equal(key_to_match label_key, pat pattern)
RETURNS matcher_negative
AS $func$
    SELECT COALESCE(array_agg(l.id), array[]::int[])::matcher_negative
    FROM label l
    WHERE l.key = key_to_match and l.value = pat
$func$
LANGUAGE SQL STABLE PARALLEL SAFE
SUPPORT @extschema@.rewrite_fn_call_to_subquery;

CREATE OR REPLACE FUNCTION @extschema@.label_find_key_regex(key_to_match label_key, pat pattern)
RETURNS matcher_positive
AS $func$
    SELECT COALESCE(array_agg(l.id), array[]::int[])::matcher_positive
    FROM label l
    WHERE l.key = key_to_match and l.value ~ pat
$func$
LANGUAGE SQL STABLE PARALLEL SAFE
SUPPORT @extschema@.rewrite_fn_call_to_subquery;

CREATE OR REPLACE FUNCTION @extschema@.label_find_key_not_regex(key_to_match label_key, pat pattern)
RETURNS matcher_negative
AS $func$
    SELECT COALESCE(array_agg(l.id), array[]::int[])::matcher_negative
    FROM label l
    WHERE l.key = key_to_match and l.value ~ pat
$func$
LANGUAGE SQL STABLE PARALLEL SAFE
SUPPORT @extschema@.rewrite_fn_call_to_subquery;

"#,
    name = "attach_support_to_label_find_key_equal",
    requires = ["promscale_setup"]
);

extension_sql!(
    r#"
GRANT EXECUTE ON FUNCTION @extschema@.label_find_key_equal(label_key, pattern) TO prom_reader;
GRANT EXECUTE ON FUNCTION @extschema@.label_find_key_not_equal(label_key, pattern) TO prom_reader;
GRANT EXECUTE ON FUNCTION @extschema@.label_find_key_regex(label_key, pattern) TO prom_reader;
GRANT EXECUTE ON FUNCTION @extschema@.label_find_key_not_regex(label_key, pattern) TO prom_reader;
"#,
    name = "grant_exec_label_find_key_equal",
    requires = ["attach_support_to_label_find_key_equal", "promscale_setup"]
);

extension_sql!(
    r#"
CREATE OPERATOR @extschema@.== (
    LEFTARG = label_key,
    RIGHTARG = pattern,
    FUNCTION = @extschema@.label_find_key_equal
);

CREATE OPERATOR @extschema@.!== (
    LEFTARG = label_key,
    RIGHTARG = pattern,
    FUNCTION = @extschema@.label_find_key_not_equal
);

CREATE OPERATOR @extschema@.==~ (
    LEFTARG = label_key,
    RIGHTARG = pattern,
    FUNCTION = @extschema@.label_find_key_regex
);

CREATE OPERATOR @extschema@.!=~ (
    LEFTARG = label_key,
    RIGHTARG = pattern,
    FUNCTION = @extschema@.label_find_key_not_regex
);
"#,
    name = "create_label_key_operators",
    requires = ["attach_support_to_label_find_key_equal"]
);
