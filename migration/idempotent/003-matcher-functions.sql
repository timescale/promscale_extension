
CREATE OR REPLACE FUNCTION _prom_catalog.count_jsonb_keys(j jsonb)
RETURNS INT
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    SELECT pg_catalog.count(*)::int from (SELECT pg_catalog.jsonb_object_keys(j)) v;
$func$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.count_jsonb_keys(jsonb) TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.label_value_contains(labels prom_api.label_value_array, label_value TEXT)
RETURNS BOOLEAN
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    SELECT labels OPERATOR(prom_api.@>) ARRAY[label_value]::pg_catalog.text[]
$func$
LANGUAGE SQL STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.label_value_contains(prom_api.label_value_array, TEXT) TO prom_reader;

CREATE OR REPLACE FUNCTION prom_api.matcher(labels jsonb)
RETURNS prom_api.matcher_positive
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    SELECT ARRAY(
           SELECT coalesce(l.id, -1) -- -1 indicates no such label
           FROM _prom_catalog.label_jsonb_each_text(labels OPERATOR(pg_catalog.-) '__name__') e
           LEFT JOIN _prom_catalog.label l
               ON (l.key OPERATOR(pg_catalog.=) e.key AND l.value OPERATOR(pg_catalog.=) e.value)
        )::prom_api.matcher_positive
$func$
LANGUAGE SQL STABLE PARALLEL SAFE;
COMMENT ON FUNCTION prom_api.matcher(jsonb)
IS 'returns a matcher for the JSONB, __name__ is ignored. The matcher can be used to match against a label array using @> or ? operators';
GRANT EXECUTE ON FUNCTION prom_api.matcher(jsonb) TO prom_reader;

---------------- eq functions ------------------

CREATE OR REPLACE FUNCTION prom_api.eq(labels1 prom_api.label_array, labels2 prom_api.label_array)
RETURNS BOOLEAN
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    --assumes labels have metric name in position 1 and have no duplicate entries
    SELECT pg_catalog.array_length(labels1, 1) OPERATOR(pg_catalog.=) pg_catalog.array_length(labels2, 1) AND labels1 OPERATOR(prom_api.@>) labels2[2:]
$func$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
COMMENT ON FUNCTION prom_api.eq(prom_api.label_array, prom_api.label_array)
IS 'returns true if two label arrays are equal, ignoring the metric name';
GRANT EXECUTE ON FUNCTION prom_api.eq(prom_api.label_array, prom_api.label_array) TO prom_reader;

CREATE OR REPLACE FUNCTION prom_api.eq(labels1 prom_api.label_array, matchers prom_api.matcher_positive)
RETURNS BOOLEAN
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    --assumes no duplicate entries
     SELECT pg_catalog.array_length(labels1, 1) OPERATOR(pg_catalog.=) (pg_catalog.array_length(matchers, 1) OPERATOR(pg_catalog.+) 1)
            AND labels1 OPERATOR(pg_catalog.@>) matchers
$func$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
COMMENT ON FUNCTION prom_api.eq(prom_api.label_array, prom_api.matcher_positive)
IS 'returns true if the label array and matchers are equal, there should not be a matcher for the metric name';
GRANT EXECUTE ON FUNCTION prom_api.eq(prom_api.label_array, prom_api.matcher_positive) TO prom_reader;

CREATE OR REPLACE FUNCTION prom_api.eq(labels prom_api.label_array, json_labels jsonb)
RETURNS BOOLEAN
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    --assumes no duplicate entries
    --do not call eq(label_array, matchers) to allow inlining
     SELECT pg_catalog.array_length(labels, 1) OPERATOR(pg_catalog.=) (_prom_catalog.count_jsonb_keys(json_labels OPERATOR(pg_catalog.-) '__name__') OPERATOR(pg_catalog.+) 1)
            AND labels OPERATOR(pg_catalog.@>) prom_api.matcher(json_labels)
$func$
LANGUAGE SQL STABLE PARALLEL SAFE;
COMMENT ON FUNCTION prom_api.eq(prom_api.label_array, jsonb)
IS 'returns true if the labels and jsonb are equal, ignoring the metric name';
GRANT EXECUTE ON FUNCTION prom_api.eq(prom_api.label_array, jsonb) TO prom_reader;

--------------------- op @> ------------------------

CREATE OR REPLACE FUNCTION _prom_catalog.label_contains(labels prom_api.label_array, json_labels jsonb)
RETURNS BOOLEAN
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    SELECT labels OPERATOR(pg_catalog.@>) prom_api.matcher(json_labels)
$func$
LANGUAGE SQL STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.label_contains(prom_api.label_array, jsonb) TO prom_reader;


--------------------- op ? ------------------------

CREATE OR REPLACE FUNCTION _prom_catalog.label_match(labels prom_api.label_array, matchers prom_api.matcher_positive)
RETURNS BOOLEAN
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    SELECT labels OPERATOR(pg_catalog.&&) matchers
$func$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.label_match(prom_api.label_array, prom_api.matcher_positive) TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.label_match(labels prom_api.label_array, matchers prom_api.matcher_negative)
RETURNS BOOLEAN
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    SELECT NOT (labels OPERATOR(pg_catalog.&&) matchers)
$func$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION _prom_catalog.label_match(prom_api.label_array, prom_api.matcher_negative) TO prom_reader;

--------------------- op == !== ==~ !=~ ------------------------

CREATE OR REPLACE FUNCTION _prom_catalog.label_find_key_equal(key_to_match prom_api.label_key, pat prom_api.pattern)
RETURNS prom_api.matcher_positive
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    SELECT COALESCE(pg_catalog.array_agg(l.id), array[]::int[])::prom_api.matcher_positive
    FROM _prom_catalog.label l
    WHERE l.key OPERATOR(pg_catalog.=) key_to_match and l.value OPERATOR(pg_catalog.=) pat
$func$
LANGUAGE SQL STABLE PARALLEL SAFE
SUPPORT _prom_ext.rewrite_fn_call_to_subquery;
GRANT EXECUTE ON FUNCTION _prom_catalog.label_find_key_equal(prom_api.label_key, prom_api.pattern) TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.label_find_key_not_equal(key_to_match prom_api.label_key, pat prom_api.pattern)
RETURNS prom_api.matcher_negative
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    SELECT COALESCE(pg_catalog.array_agg(l.id), array[]::int[])::prom_api.matcher_negative
    FROM _prom_catalog.label l
    WHERE l.key OPERATOR(pg_catalog.=) key_to_match and l.value OPERATOR(pg_catalog.=) pat
$func$
LANGUAGE SQL STABLE PARALLEL SAFE
SUPPORT _prom_ext.rewrite_fn_call_to_subquery;
GRANT EXECUTE ON FUNCTION _prom_catalog.label_find_key_not_equal(prom_api.label_key, prom_api.pattern) TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.label_find_key_regex(key_to_match prom_api.label_key, pat prom_api.pattern)
RETURNS prom_api.matcher_positive
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    SELECT COALESCE(pg_catalog.array_agg(l.id), array[]::int[])::prom_api.matcher_positive
    FROM _prom_catalog.label l
    WHERE l.key OPERATOR(pg_catalog.=) key_to_match and l.value OPERATOR(pg_catalog.~) pat
$func$
LANGUAGE SQL STABLE PARALLEL SAFE
SUPPORT _prom_ext.rewrite_fn_call_to_subquery;
GRANT EXECUTE ON FUNCTION _prom_catalog.label_find_key_regex(prom_api.label_key, prom_api.pattern) TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.label_find_key_not_regex(key_to_match prom_api.label_key, pat prom_api.pattern)
RETURNS prom_api.matcher_negative
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    SELECT COALESCE(pg_catalog.array_agg(l.id), array[]::int[])::prom_api.matcher_negative
    FROM _prom_catalog.label l
    WHERE l.key OPERATOR(pg_catalog.=) key_to_match and l.value OPERATOR(pg_catalog.~) pat
$func$
LANGUAGE SQL STABLE PARALLEL SAFE
SUPPORT _prom_ext.rewrite_fn_call_to_subquery;
GRANT EXECUTE ON FUNCTION _prom_catalog.label_find_key_not_regex(prom_api.label_key, prom_api.pattern) TO prom_reader;

--------------------- op == !== ==~ !=~ ------------------------

CREATE OR REPLACE FUNCTION _prom_catalog.match_equals(labels prom_api.label_array, _op ps_tag.tag_op_equals)
RETURNS boolean
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    SELECT labels OPERATOR(pg_catalog.&&) _prom_catalog.label_find_key_equal(_op.tag_key, (_op.value OPERATOR(pg_catalog.#>>) '{}'))::int[]
$func$
LANGUAGE SQL STABLE PARALLEL SAFE; -- do not make strict. it disables function inlining
GRANT EXECUTE ON FUNCTION _prom_catalog.match_equals(prom_api.label_array, ps_tag.tag_op_equals) TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.match_not_equals(labels prom_api.label_array, _op ps_tag.tag_op_not_equals)
RETURNS boolean
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    SELECT NOT (labels OPERATOR(pg_catalog.&&) _prom_catalog.label_find_key_not_equal(_op.tag_key, (_op.value OPERATOR(pg_catalog.#>>) '{}'))::int[])
$func$
LANGUAGE SQL STABLE PARALLEL SAFE; -- do not make strict. it disables function inlining
GRANT EXECUTE ON FUNCTION _prom_catalog.match_not_equals(prom_api.label_array, ps_tag.tag_op_not_equals) TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.match_regexp_matches(labels prom_api.label_array, _op ps_tag.tag_op_regexp_matches)
RETURNS boolean
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    SELECT labels OPERATOR(pg_catalog.&&) _prom_catalog.label_find_key_regex(_op.tag_key, _op.value)::int[]
$func$
LANGUAGE SQL STABLE PARALLEL SAFE; -- do not make strict. it disables function inlining
GRANT EXECUTE ON FUNCTION _prom_catalog.match_regexp_matches(prom_api.label_array, ps_tag.tag_op_regexp_matches) TO prom_reader;

CREATE OR REPLACE FUNCTION _prom_catalog.match_regexp_not_matches(labels prom_api.label_array, _op ps_tag.tag_op_regexp_not_matches)
RETURNS boolean
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $func$
    SELECT NOT (labels OPERATOR(pg_catalog.&&) _prom_catalog.label_find_key_not_regex(_op.tag_key, _op.value)::int[])
$func$
LANGUAGE SQL STABLE PARALLEL SAFE; -- do not make strict. it disables function inlining
GRANT EXECUTE ON FUNCTION _prom_catalog.match_regexp_not_matches(prom_api.label_array, ps_tag.tag_op_regexp_not_matches) TO prom_reader;
