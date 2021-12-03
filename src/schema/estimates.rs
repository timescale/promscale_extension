//! Here we wrap some postgres functions to provide better row estimates for
//! some postgres functions with default estimates which are off by and order
//! of magnitude

use pgx::*;

// wrapper around jsonb_each_text to give a better row_estimate
// for labels (10 not 100)
extension_sql!(
    r#"
CREATE OR REPLACE FUNCTION @extschema@.label_jsonb_each_text(js jsonb, OUT key text, OUT value text)
    RETURNS SETOF record
    LANGUAGE internal
    IMMUTABLE PARALLEL SAFE STRICT ROWS 10
AS $function$jsonb_each_text$function$;
GRANT EXECUTE ON FUNCTION @extschema@.label_jsonb_each_text(jsonb) TO prom_reader;
    "#,
    name = "create_label_jsonb_each_text_row_estimate_wrapper",
    requires = ["promscale_setup"]
);

// wrapper around unnest to give better row estimate (10 not 100)
extension_sql!(
    r#"
CREATE OR REPLACE FUNCTION @extschema@.label_unnest(label_array anyarray)
RETURNS SETOF anyelement
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT ROWS 10
AS $function$array_unnest$function$;
GRANT EXECUTE ON FUNCTION @extschema@.label_unnest(anyarray) TO prom_reader;
    "#,
    name = "create_label_unnest_row_estimate_wrapper",
    requires = ["promscale_setup"]
);
