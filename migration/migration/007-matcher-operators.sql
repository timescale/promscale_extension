----------------------------------
-- Label selectors and matchers --
----------------------------------
-- This section contains a few functions that we're going to replace in the idempotent section.
-- They are created here just to allow us to create the necessary operators.

CREATE DOMAIN prom_api.matcher_positive AS int[] NOT NULL;
CREATE DOMAIN prom_api.matcher_negative AS int[] NOT NULL;
CREATE DOMAIN prom_api.label_key AS TEXT NOT NULL;
CREATE DOMAIN prom_api.pattern AS TEXT NOT NULL;

--wrapper around jsonb_each_text to give a better row_estimate
--for labels (10 not 100)
CREATE OR REPLACE FUNCTION _prom_catalog.label_jsonb_each_text(js jsonb, OUT key text, OUT value text)
 RETURNS SETOF record
 LANGUAGE INTERNAL
 IMMUTABLE PARALLEL SAFE STRICT ROWS 10
AS $function$jsonb_each_text$function$;

CREATE OR REPLACE FUNCTION _prom_catalog.count_jsonb_keys(j jsonb)
RETURNS INT
-- Note: no explicit search_path because we want inlining
AS $func$
    SELECT pg_catalog.count(*)::int from (SELECT pg_catalog.jsonb_object_keys(j)) v;
$func$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.count_jsonb_keys(jsonb) TO prom_reader;

CREATE OR REPLACE FUNCTION prom_api.matcher(labels jsonb)
RETURNS prom_api.matcher_positive
-- Note: no explicit search_path because we want inlining
AS $func$
    SELECT ARRAY(
           SELECT coalesce(l.id, -1) -- -1 indicates no such label
           FROM _prom_catalog.label_jsonb_each_text(labels OPERATOR(pg_catalog.-) '__name__') e
           LEFT JOIN _prom_catalog.label l
               ON (l.key OPERATOR(pg_catalog.=) e.key AND l.value OPERATOR(pg_catalog.=) e.value)
        )::prom_api.matcher_positive
$func$
LANGUAGE SQL STABLE PARALLEL SAFE;

--------------------- op @> ------------------------

CREATE OR REPLACE FUNCTION _prom_catalog.label_contains(labels prom_api.label_array, json_labels jsonb)
RETURNS BOOLEAN
-- Note: no explicit search_path because we want inlining
AS $func$
    SELECT labels OPERATOR(prom_api.@>) prom_api.matcher(json_labels)
$func$
LANGUAGE SQL STABLE PARALLEL SAFE;

CREATE OPERATOR prom_api.@> (
    LEFTARG = prom_api.label_array,
    RIGHTARG = jsonb,
    FUNCTION = _prom_catalog.label_contains
);

CREATE OR REPLACE FUNCTION _prom_catalog.label_value_contains(labels prom_api.label_value_array, label_value TEXT)
RETURNS BOOLEAN
-- Note: no explicit search_path because we want inlining
AS $func$
    SELECT labels OPERATOR(prom_api.@>) ARRAY[label_value]::TEXT[]
$func$
LANGUAGE SQL STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.label_value_contains(prom_api.label_value_array, TEXT) TO prom_reader;

CREATE OPERATOR prom_api.@> (
    LEFTARG = prom_api.label_value_array,
    RIGHTARG = TEXT,
    FUNCTION = _prom_catalog.label_value_contains
);

--------------------- op ? ------------------------

CREATE OR REPLACE FUNCTION _prom_catalog.label_match(labels prom_api.label_array, matchers prom_api.matcher_positive)
RETURNS BOOLEAN
-- Note: no explicit search_path because we want inlining
AS $func$
    SELECT labels OPERATOR(pg_catalog.&&) matchers
$func$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;

CREATE OPERATOR prom_api.? (
    LEFTARG = prom_api.label_array,
    RIGHTARG = prom_api.matcher_positive,
    FUNCTION = _prom_catalog.label_match
);

CREATE OR REPLACE FUNCTION _prom_catalog.label_match(labels prom_api.label_array, matchers prom_api.matcher_negative)
RETURNS BOOLEAN
-- Note: no explicit search_path because we want inlining
AS $func$
    SELECT NOT (labels OPERATOR(pg_catalog.&&) matchers)
$func$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;

CREATE OPERATOR prom_api.? (
    LEFTARG = prom_api.label_array,
    RIGHTARG = prom_api.matcher_negative,
    FUNCTION = _prom_catalog.label_match
);

--------------------- op == !== ==~ !=~ ------------------------

CREATE OR REPLACE FUNCTION _prom_catalog.label_find_key_equal(key_to_match prom_api.label_key, pat prom_api.pattern)
RETURNS prom_api.matcher_positive
-- Note: no explicit search_path because we want inlining
AS $func$
    SELECT COALESCE(pg_catalog.array_agg(l.id), array[]::int[])::prom_api.matcher_positive
    FROM _prom_catalog.label l
    WHERE l.key OPERATOR(pg_catalog.=) key_to_match and l.value OPERATOR(pg_catalog.=) pat
$func$
LANGUAGE SQL STABLE PARALLEL SAFE
SUPPORT _prom_ext.rewrite_fn_call_to_subquery;

CREATE OR REPLACE FUNCTION _prom_catalog.label_find_key_not_equal(key_to_match prom_api.label_key, pat prom_api.pattern)
RETURNS prom_api.matcher_negative
-- Note: no explicit search_path because we want inlining
AS $func$
    SELECT COALESCE(pg_catalog.array_agg(l.id), array[]::int[])::prom_api.matcher_negative
    FROM _prom_catalog.label l
    WHERE l.key OPERATOR(pg_catalog.=) key_to_match and l.value OPERATOR(pg_catalog.=) pat
$func$
LANGUAGE SQL STABLE PARALLEL SAFE
SUPPORT _prom_ext.rewrite_fn_call_to_subquery;

CREATE OR REPLACE FUNCTION _prom_catalog.label_find_key_regex(key_to_match prom_api.label_key, pat prom_api.pattern)
RETURNS prom_api.matcher_positive
-- Note: no explicit search_path because we want inlining
AS $func$
    SELECT COALESCE(pg_catalog.array_agg(l.id), array[]::int[])::prom_api.matcher_positive
    FROM _prom_catalog.label l
    WHERE l.key OPERATOR(pg_catalog.=) key_to_match and l.value OPERATOR(pg_catalog.~) pat
$func$
LANGUAGE SQL STABLE PARALLEL SAFE
SUPPORT _prom_ext.rewrite_fn_call_to_subquery;

CREATE OR REPLACE FUNCTION _prom_catalog.label_find_key_not_regex(key_to_match prom_api.label_key, pat prom_api.pattern)
RETURNS prom_api.matcher_negative
-- Note: no explicit search_path because we want inlining
AS $func$
    SELECT COALESCE(pg_catalog.array_agg(l.id), array[]::int[])::prom_api.matcher_negative
    FROM _prom_catalog.label l
    WHERE l.key OPERATOR(pg_catalog.=) key_to_match and l.value OPERATOR(pg_catalog.~) pat
$func$
LANGUAGE SQL STABLE PARALLEL SAFE
SUPPORT _prom_ext.rewrite_fn_call_to_subquery;

CREATE OR REPLACE FUNCTION _prom_catalog.match_equals(labels prom_api.label_array, _op ps_tag.tag_op_equals)
RETURNS boolean
-- Note: no explicit search_path because we want inlining
AS $func$
    SELECT labels OPERATOR(pg_catalog.&&) _prom_catalog.label_find_key_equal(_op.tag_key, (_op.value OPERATOR(pg_catalog.#>>)'{}'))::int[]
$func$
LANGUAGE SQL STABLE PARALLEL SAFE; -- do not make strict. it disables function inlining

CREATE OPERATOR _prom_catalog.? (
    LEFTARG = prom_api.label_array,
    RIGHTARG = ps_tag.tag_op_equals,
    FUNCTION = _prom_catalog.match_equals
);

CREATE OR REPLACE FUNCTION _prom_catalog.match_not_equals(labels prom_api.label_array, _op ps_tag.tag_op_not_equals)
RETURNS boolean
-- Note: no explicit search_path because we want inlining
AS $func$
    SELECT NOT (labels OPERATOR(pg_catalog.&&) _prom_catalog.label_find_key_not_equal(_op.tag_key, (_op.value OPERATOR(pg_catalog.#>>) '{}'))::int[])
$func$
LANGUAGE SQL STABLE PARALLEL SAFE; -- do not make strict. it disables function inlining

CREATE OPERATOR _prom_catalog.? (
    LEFTARG = prom_api.label_array,
    RIGHTARG = ps_tag.tag_op_not_equals,
    FUNCTION = _prom_catalog.match_not_equals
);

CREATE OR REPLACE FUNCTION _prom_catalog.match_regexp_matches(labels prom_api.label_array, _op ps_tag.tag_op_regexp_matches)
RETURNS boolean
-- Note: no explicit search_path because we want inlining
AS $func$
    SELECT labels OPERATOR(pg_catalog.&&) _prom_catalog.label_find_key_regex(_op.tag_key, _op.value)::int[]
$func$
LANGUAGE SQL STABLE PARALLEL SAFE; -- do not make strict. it disables function inlining

CREATE OPERATOR _prom_catalog.? (
    LEFTARG = prom_api.label_array,
    RIGHTARG = ps_tag.tag_op_regexp_matches,
    FUNCTION = _prom_catalog.match_regexp_matches
);

CREATE OR REPLACE FUNCTION _prom_catalog.match_regexp_not_matches(labels prom_api.label_array, _op ps_tag.tag_op_regexp_not_matches)
RETURNS boolean
-- Note: no explicit search_path because we want inlining
AS $func$
    SELECT NOT (labels OPERATOR(pg_catalog.&&) _prom_catalog.label_find_key_not_regex(_op.tag_key, _op.value)::int[])
$func$
LANGUAGE SQL STABLE PARALLEL SAFE; -- do not make strict. it disables function inlining

CREATE OPERATOR _prom_catalog.? (
    LEFTARG = prom_api.label_array,
    RIGHTARG = ps_tag.tag_op_regexp_not_matches,
    FUNCTION = _prom_catalog.match_regexp_not_matches
);
