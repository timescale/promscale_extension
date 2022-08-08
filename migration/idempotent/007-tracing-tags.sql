-------------------------------------------------------------------------------
-- Tag_map related functions and operators
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION _ps_trace.tag_map_denormalize(_map ps_trace.tag_map)
    RETURNS ps_trace.tag_map
    LANGUAGE sql STABLE
    PARALLEL SAFE AS
/* NOTE: This function cannot be inlined since it's used in a scalar
 * context and uses an aggregate. Yet we don't want to use `SET` clause
 * for the search_path, thus it is important to make it completely
 * search_path-agnostic.
 */
$fnc$
    SELECT pg_catalog.jsonb_object_agg(t.key, t.value::pg_catalog.jsonb)
        FROM pg_catalog.jsonb_each(_map) f(k,v)
            JOIN _ps_trace.tag t ON f.v::pg_catalog.int8 OPERATOR(pg_catalog.=) t.id;
$fnc$;

GRANT EXECUTE ON FUNCTION _ps_trace.tag_map_denormalize(ps_trace.tag_map) TO prom_reader;

COMMENT ON FUNCTION _ps_trace.tag_map_denormalize
IS 'Given a json object of (ps_trace.tag_key.id, ps_trace.tag.id) this function
performs necessary lookups and returns a reconstructed set of open telemetry tags
as a tag_map.';

-------------------------------------------------------------------------------
-- the -> operator
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ps_trace.tag_map_object_field(ps_trace.tag_map, pg_catalog.text)
    RETURNS _ps_trace.tag_v
    STRICT
    LANGUAGE internal AS 'jsonb_object_field';
GRANT EXECUTE ON FUNCTION ps_trace.tag_map_object_field(ps_trace.tag_map, pg_catalog.text) TO prom_reader;
COMMENT ON FUNCTION ps_trace.tag_map_object_field
IS 'This function is a part of custom ps_trace.tag_map type which is a wrapper for
the built-in jsonb. It is the same as its jsonb_ namesake, but returns _ps_trace.tag_v.';

DO $do$
BEGIN
	CREATE OPERATOR ps_trace.->	(
	    FUNCTION = ps_trace.tag_map_object_field,
	    LEFTARG  = ps_trace.tag_map,
	    RIGHTARG = pg_catalog.text
	);
EXCEPTION
    WHEN SQLSTATE '42723' THEN -- operator already exists
        EXECUTE format($q$ALTER OPERATOR ps_trace.->(ps_trace.tag_map, pg_catalog.text) OWNER TO %I$q$, current_user);
END;
$do$;
COMMENT ON OPERATOR ps_trace.-> (ps_trace.tag_map, pg_catalog.text)
IS 'This operator is a part of custom ps_trace.tag_map type which is a wrapper for
the built-in jsonb. It is the same as its jsonb_ namesake, but returns _ps_trace.tag_v.';

-------------------------------------------------------------------------------
-- equals
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ps_trace.tag_v_eq(_ps_trace.tag_v, pg_catalog.jsonb)
    RETURNS pg_catalog.bool
    LANGUAGE internal
        IMMUTABLE
        STRICT
        PARALLEL SAFE
        SUPPORT _prom_ext.tag_map_rewrite
    AS 'jsonb_eq';
GRANT EXECUTE ON FUNCTION ps_trace.tag_v_eq(_ps_trace.tag_v, pg_catalog.jsonb) TO prom_reader;
COMMENT ON FUNCTION ps_trace.tag_v_eq(_ps_trace.tag_v, pg_catalog.jsonb)
IS 'This function is a part of custom _ps_trace.tag_v type which is a wrapper for
the built-in jsonb. It is the same as its jsonb_ namesake, but has a support function attached.';

CREATE OR REPLACE FUNCTION ps_trace.tag_v_eq(_ps_trace.tag_v, _ps_trace.tag_v)
    RETURNS pg_catalog.bool
    LANGUAGE internal
        IMMUTABLE
        STRICT
        PARALLEL SAFE
    AS 'jsonb_eq';
GRANT EXECUTE ON FUNCTION ps_trace.tag_v_eq(_ps_trace.tag_v, _ps_trace.tag_v) TO prom_reader;

COMMENT ON FUNCTION ps_trace.tag_v_eq(_ps_trace.tag_v, _ps_trace.tag_v)
IS 'This function is a part of custom _ps_trace.tag_v type which is a wrapper for
the built-in jsonb. It is the same as its jsonb_ namesake, but has a support function attached.';

CREATE OR REPLACE FUNCTION _ps_trace.tag_v_eq_matching_tags(_tag_key pg_catalog.text, _value pg_catalog.jsonb)
    RETURNS pg_catalog.jsonb
    LANGUAGE sql STABLE
    -- Note: no explicit `SET SCHEMA` because we want this function to be inlined
    PARALLEL SAFE AS
$fnc$
    SELECT pg_catalog.jsonb_build_object(a.key_id, a.id)
    FROM _ps_trace.tag a
    WHERE a.key OPERATOR(pg_catalog.=) _tag_key
    AND _prom_ext.jsonb_digest(a.value) OPERATOR(pg_catalog.=) _prom_ext.jsonb_digest(_value)
    AND a.value OPERATOR(pg_catalog.=) _value
    LIMIT 1
$fnc$;
GRANT EXECUTE ON FUNCTION _ps_trace.tag_v_eq_matching_tags(_tag_key pg_catalog.text, _value pg_catalog.jsonb) TO prom_reader;
COMMENT ON FUNCTION _ps_trace.tag_v_eq_matching_tags
IS 'This function is a part of custom _ps_trace.tag_v type which is a wrapper for
the built-in jsonb. The tag_map_rewrite support function, attached to tag_v_eq,
will use this function instead, if it can.';

CREATE OR REPLACE FUNCTION _ps_trace.text_matches(_value pg_catalog.text)
    RETURNS pg_catalog.jsonb[]
    --note: to_jsonb is stable, not immutable because of timestamptz handling which does not apply here.
    --so this is safe.
    LANGUAGE sql IMMUTABLE
    -- Note: no explicit `SET SCHEMA` because we want this function to be inlined
    PARALLEL SAFE AS
$fnc$
SELECT CASE
 WHEN _value OPERATOR(pg_catalog.=) ANY(array['true', 'false']) THEN ARRAY[pg_catalog.to_jsonb(_value), pg_catalog.to_jsonb(_value::pg_catalog.bool)]
 --regex from https://www.regular-expressions.info/floatingpoint.html
 --the jsonb internals all use numeric types for maniplation so use numeric here too (as opposed to float)
 WHEN _value OPERATOR(pg_catalog.~) '^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$' THEN ARRAY[pg_catalog.to_jsonb(_value), pg_catalog.to_jsonb(_value::pg_catalog.numeric)]
 ELSE ARRAY[pg_catalog.to_jsonb(_value)]
END
$fnc$;
GRANT EXECUTE ON FUNCTION _ps_trace.text_matches(_value pg_catalog.text) TO prom_reader;
COMMENT ON FUNCTION _ps_trace.text_matches
IS 'This function is an internal function that given a peice of text, returns all the possible
jsonb representations of that text. I.e. it is the inverse of the jsonb ->> operator.';

CREATE OR REPLACE FUNCTION _ps_trace.tag_v_text_eq_matching_tags(_tag_key pg_catalog.text, _tag_value_text pg_catalog.text)
    RETURNS pg_catalog.jsonb[]
    LANGUAGE sql STABLE
    SET search_path = pg_catalog, pg_temp
    PARALLEL SAFE AS
$fnc$
    SELECT coalesce(pg_catalog.array_agg(pg_catalog.jsonb_build_object(a.key_id, a.id)), array[]::pg_catalog.jsonb[])
    FROM
    (
            SELECT v, _prom_ext.jsonb_digest(v) as digest
            FROM unnest(_ps_trace.text_matches(_tag_value_text)) as v
    ) as matchers
    INNER JOIN LATERAL (
        SELECT t.*
        FROM _ps_trace.tag t
        WHERE t.key OPERATOR(pg_catalog.=) _tag_key
        AND _prom_ext.jsonb_digest(t.value) OPERATOR(pg_catalog.=) matchers.digest
        AND t.value OPERATOR(pg_catalog.=) matchers.v
        LIMIT 1
    ) as a on (true);
$fnc$;
GRANT EXECUTE ON FUNCTION _ps_trace.tag_v_text_eq_matching_tags(_tag_key pg_catalog.text, _tag_value_text pg_catalog.text) TO prom_reader;
COMMENT ON FUNCTION _ps_trace.tag_v_text_eq_matching_tags
IS 'This function is a part of custom _ps_trace.tag_v type which is a wrapper for
the built-in jsonb. This function returns all the jsonb { tag_key_id, tag_value_id } pairs where
the tag key matches _tag_key and the textual output of tag value matches _tag_value_text';


DO $do$
BEGIN
	CREATE OPERATOR ps_trace.= (
	    FUNCTION       = ps_trace.tag_v_eq,
	    LEFTARG        = _ps_trace.tag_v,
	    RIGHTARG       = pg_catalog.jsonb,
        NEGATOR        = OPERATOR(ps_trace.<>),
	    RESTRICT       = eqsel,
	    JOIN           = eqjoinsel,
	    HASHES, MERGES
	);
EXCEPTION
    WHEN SQLSTATE '42723' THEN -- operator already exists
        EXECUTE format($q$ALTER OPERATOR ps_trace.=(_ps_trace.tag_v, pg_catalog.jsonb) OWNER TO %I$q$, current_user);
END;
$do$;
COMMENT ON OPERATOR ps_trace.= (_ps_trace.tag_v, pg_catalog.jsonb)
IS 'This operator is a part of custom ps_trace.tag_map type which is a wrapper for
the built-in jsonb. It is the same as its jsonb_ namesake, but relies on tag_map_* functions.';


DO $do$
BEGIN
	CREATE OPERATOR ps_trace.%= (
	    FUNCTION       = ps_trace.tag_v_eq,
	    LEFTARG        = _ps_trace.tag_v,
	    RIGHTARG       = _ps_trace.tag_v,
        NEGATOR        = OPERATOR(ps_trace.%<>),
	    RESTRICT       = eqsel,
	    JOIN           = eqjoinsel,
	    HASHES, MERGES
	);
EXCEPTION
    WHEN SQLSTATE '42723' THEN -- operator already exists
        EXECUTE format($q$ALTER OPERATOR ps_trace.%=(_ps_trace.tag_v, _ps_trace.tag_v) OWNER TO %I$q$, current_user);
END;
$do$;
COMMENT ON OPERATOR ps_trace.%= (_ps_trace.tag_v, _ps_trace.tag_v)
IS 'This operator is a part of custom ps_trace.tag_map type which is a wrapper for
the built-in jsonb. It is the same as its jsonb_ namesake, but relies on tag_map_* functions.';

-------------------------------------------------------------------------------
-- not equals
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ps_trace.tag_v_ne(_ps_trace.tag_v, pg_catalog.jsonb)
    RETURNS pg_catalog.bool
    LANGUAGE internal
        IMMUTABLE
        STRICT
        PARALLEL SAFE
        SUPPORT _prom_ext.tag_map_rewrite
    AS 'jsonb_ne';
GRANT EXECUTE ON FUNCTION ps_trace.tag_v_ne(_ps_trace.tag_v, pg_catalog.jsonb) TO prom_reader;
COMMENT ON FUNCTION ps_trace.tag_v_ne(_ps_trace.tag_v, pg_catalog.jsonb)
IS 'This function is a part of custom _ps_trace.tag_v type which is a wrapper for
the built-in jsonb. It is the same as its jsonb_ namesake, but has a support function attached.';

CREATE OR REPLACE FUNCTION ps_trace.tag_v_ne(_ps_trace.tag_v, _ps_trace.tag_v)
    RETURNS pg_catalog.bool
    LANGUAGE internal
        IMMUTABLE
        STRICT
        PARALLEL SAFE
        SUPPORT _prom_ext.tag_map_rewrite
    AS 'jsonb_ne';
GRANT EXECUTE ON FUNCTION ps_trace.tag_v_ne(_ps_trace.tag_v, _ps_trace.tag_v) TO prom_reader;
COMMENT ON FUNCTION ps_trace.tag_v_ne(_ps_trace.tag_v, _ps_trace.tag_v)
IS 'This function is a part of custom _ps_trace.tag_v type which is a wrapper for
the built-in jsonb. It is the same as its jsonb_ namesake, but has a support function attached.';

CREATE OR REPLACE FUNCTION _ps_trace.tag_v_ne_matching_tags(_tag_key pg_catalog.text, _value pg_catalog.jsonb)
    RETURNS pg_catalog.jsonb[]
    LANGUAGE sql STABLE
    -- Note: no explicit `SET SCHEMA` because we want this function to be inlined
    PARALLEL SAFE AS
$fnc$
    SELECT coalesce(pg_catalog.array_agg(pg_catalog.jsonb_build_object(a.key_id, a.id)), array[]::pg_catalog.jsonb[])
    FROM _ps_trace.tag a
    WHERE a.key OPERATOR(pg_catalog.=) _tag_key
    AND a.value OPERATOR(pg_catalog.<>) _value
$fnc$;
GRANT EXECUTE ON FUNCTION _ps_trace.tag_v_ne_matching_tags(_tag_key pg_catalog.text, _value pg_catalog.jsonb) TO prom_reader;
COMMENT ON FUNCTION _ps_trace.tag_v_ne_matching_tags
IS 'This function is a part of custom _ps_trace.tag_v type which is a wrapper for
the built-in jsonb. The tag_map_rewrite support function, attached to tag_v_ne,
will use this function instead, if it can.';


DO $do$
BEGIN
	CREATE OPERATOR ps_trace.<> (
	    FUNCTION       = ps_trace.tag_v_ne,
	    LEFTARG        = _ps_trace.tag_v,
	    RIGHTARG       = pg_catalog.jsonb,
	    NEGATOR        = OPERATOR(ps_trace.=),
	    RESTRICT       = neqsel,
	    JOIN           = neqjoinsel
	);
EXCEPTION
    WHEN SQLSTATE '42723' THEN -- operator already exists
        EXECUTE format($q$ALTER OPERATOR ps_trace.<>(_ps_trace.tag_v, pg_catalog.jsonb) OWNER TO %I$q$, current_user);
END;
$do$;
COMMENT ON OPERATOR ps_trace.<> (_ps_trace.tag_v, pg_catalog.jsonb)
IS 'This operator is a part of custom ps_trace.tag_map type which is a wrapper for
the built-in jsonb. It is the same as its jsonb_ namesake, but relies on tag_map_* functions.';

DO $do$
BEGIN
	CREATE OPERATOR ps_trace.%<> (
	    FUNCTION       = ps_trace.tag_v_ne,
	    LEFTARG        = _ps_trace.tag_v,
	    RIGHTARG       = _ps_trace.tag_v,
	    NEGATOR        = OPERATOR(ps_trace.%=),
	    RESTRICT       = neqsel,
	    JOIN           = neqjoinsel
	);
EXCEPTION
    WHEN SQLSTATE '42723' THEN -- operator already exists
        EXECUTE format($q$ALTER OPERATOR ps_trace.%<>(_ps_trace.tag_v, _ps_trace.tag_v) OWNER TO %I$q$, current_user);
END;
$do$;
COMMENT ON OPERATOR ps_trace.%<> (_ps_trace.tag_v, _ps_trace.tag_v)
IS 'This operator is a part of custom ps_trace.tag_map type which is a wrapper for
the built-in jsonb. It is the same as its jsonb_ namesake, but relies on tag_map_* functions.';

-------------------------------------------------------------------------------
-- comparison
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION _ps_trace.tag_v_cmp(_ps_trace.tag_v, _ps_trace.tag_v)
    RETURNS pg_catalog.int4
    LANGUAGE internal
        IMMUTABLE
        STRICT
        PARALLEL SAFE
    AS 'jsonb_cmp';
GRANT EXECUTE ON FUNCTION _ps_trace.tag_v_cmp(_ps_trace.tag_v, _ps_trace.tag_v) TO prom_reader;
COMMENT ON FUNCTION _ps_trace.tag_v_cmp
IS 'This function is a part of custom _ps_trace.tag_v type which is a wrapper for the built-in jsonb. It is the same as its jsonb_ namesake.';

CREATE OR REPLACE FUNCTION ps_trace.tag_v_gt(_ps_trace.tag_v, _ps_trace.tag_v)
    RETURNS pg_catalog.bool
    LANGUAGE internal
        IMMUTABLE
        STRICT
        PARALLEL SAFE
    AS 'jsonb_gt';
GRANT EXECUTE ON FUNCTION ps_trace.tag_v_gt(_ps_trace.tag_v, _ps_trace.tag_v) TO prom_reader;
COMMENT ON FUNCTION ps_trace.tag_v_gt
IS 'This function is a part of custom _ps_trace.tag_v type which is a wrapper for the built-in jsonb. It is the same as its jsonb_ namesake.';

CREATE OR REPLACE FUNCTION ps_trace.tag_v_ge(_ps_trace.tag_v, _ps_trace.tag_v)
    RETURNS pg_catalog.bool
    LANGUAGE internal
        IMMUTABLE
        STRICT
        PARALLEL SAFE
    AS 'jsonb_ge';
GRANT EXECUTE ON FUNCTION ps_trace.tag_v_ge(_ps_trace.tag_v, _ps_trace.tag_v) TO prom_reader;
COMMENT ON FUNCTION ps_trace.tag_v_ge
IS 'This function is a part of custom _ps_trace.tag_v type which is a wrapper for the built-in jsonb. It is the same as its jsonb_ namesake.';

CREATE OR REPLACE FUNCTION ps_trace.tag_v_lt(_ps_trace.tag_v, _ps_trace.tag_v)
    RETURNS pg_catalog.bool
    LANGUAGE internal
        IMMUTABLE
        STRICT
        PARALLEL SAFE
    AS 'jsonb_lt';
GRANT EXECUTE ON FUNCTION ps_trace.tag_v_lt(_ps_trace.tag_v, _ps_trace.tag_v) TO prom_reader;
COMMENT ON FUNCTION ps_trace.tag_v_lt
IS 'This function is a part of custom _ps_trace.tag_v type which is a wrapper for the built-in jsonb. It is the same as its jsonb_ namesake.';

CREATE OR REPLACE FUNCTION ps_trace.tag_v_le(_ps_trace.tag_v, _ps_trace.tag_v)
    RETURNS pg_catalog.bool
    LANGUAGE internal
        IMMUTABLE
        STRICT
        PARALLEL SAFE
    AS 'jsonb_le';
GRANT EXECUTE ON FUNCTION ps_trace.tag_v_le(_ps_trace.tag_v, _ps_trace.tag_v) TO prom_reader;
COMMENT ON FUNCTION ps_trace.tag_v_le
IS 'This function is a part of custom _ps_trace.tag_v type which is a wrapper for the built-in jsonb. It is the same as its jsonb_ namesake.';

DO $do$
BEGIN
	CREATE OPERATOR ps_trace.%> (
	    FUNCTION       = ps_trace.tag_v_gt,
	    LEFTARG        = _ps_trace.tag_v,
	    RIGHTARG       = _ps_trace.tag_v,
	    NEGATOR        = OPERATOR(ps_trace.%<=),
	    RESTRICT       = scalargtsel,
	    JOIN           = scalargtjoinsel
	);
EXCEPTION
    WHEN SQLSTATE '42723' THEN -- operator already exists
        EXECUTE format($q$ALTER OPERATOR ps_trace.%>(_ps_trace.tag_v, _ps_trace.tag_v) OWNER TO %I$q$, current_user);
END;
$do$;


DO $do$
BEGIN
	CREATE OPERATOR ps_trace.%>= (
	    FUNCTION       = ps_trace.tag_v_ge,
	    LEFTARG        = _ps_trace.tag_v,
	    RIGHTARG       = _ps_trace.tag_v,
	    NEGATOR        = OPERATOR(ps_trace.%<),
	    RESTRICT       = scalargesel,
	    JOIN           = scalargejoinsel
	);
EXCEPTION
    WHEN SQLSTATE '42723' THEN -- operator already exists
        EXECUTE format($q$ALTER OPERATOR ps_trace.%>=(_ps_trace.tag_v, _ps_trace.tag_v) OWNER TO %I$q$, current_user);
END;
$do$;
COMMENT ON OPERATOR ps_trace.%>= (_ps_trace.tag_v, _ps_trace.tag_v)
IS 'This operator is a part of custom ps_trace.tag_map type which is a wrapper for
the built-in jsonb. It is the same as its jsonb_ namesake, but relies on tag_map_* functions.';

DO $do$
BEGIN
	CREATE OPERATOR ps_trace.%< (
	    FUNCTION       = ps_trace.tag_v_lt,
	    LEFTARG        = _ps_trace.tag_v,
	    RIGHTARG       = _ps_trace.tag_v,
	    NEGATOR        = OPERATOR(ps_trace.%>=),
	    RESTRICT       = scalarltsel,
	    JOIN           = scalarltjoinsel
	);
EXCEPTION
    WHEN SQLSTATE '42723' THEN -- operator already exists
        EXECUTE format($q$ALTER OPERATOR ps_trace.%<(_ps_trace.tag_v, _ps_trace.tag_v) OWNER TO %I$q$, current_user);
END;
$do$;
COMMENT ON OPERATOR ps_trace.%< (_ps_trace.tag_v, _ps_trace.tag_v)
IS 'This operator is a part of custom ps_trace.tag_map type which is a wrapper for
the built-in jsonb. It is the same as its jsonb_ namesake, but relies on tag_map_* functions.';

DO $do$
BEGIN
	CREATE OPERATOR ps_trace.%<= (
	    FUNCTION       = ps_trace.tag_v_le,
	    LEFTARG        = _ps_trace.tag_v,
	    RIGHTARG       = _ps_trace.tag_v,
	    NEGATOR        = OPERATOR(ps_trace.%>),
	    RESTRICT       = scalarlesel,
	    JOIN           = scalarlejoinsel
	);
EXCEPTION
    WHEN SQLSTATE '42723' THEN -- operator already exists
        EXECUTE format($q$ALTER OPERATOR ps_trace.%<=(_ps_trace.tag_v, _ps_trace.tag_v) OWNER TO %I$q$, current_user);
END;
$do$;
COMMENT ON OPERATOR ps_trace.%<= (_ps_trace.tag_v, _ps_trace.tag_v)
IS 'This operator is a part of custom ps_trace.tag_map type which is a wrapper for
the built-in jsonb. It is the same as its jsonb_ namesake, but relies on tag_map_* functions.';


/* Create opclass for tag_v for distinct/group by type of queries */

DO $do$
BEGIN
    CREATE OPERATOR CLASS ps_trace.btree_tag_v_ops
        DEFAULT FOR TYPE _ps_trace.tag_v USING btree
        AS
                OPERATOR        1       ps_trace.%<  ,
                OPERATOR        2       ps_trace.%<= ,
                OPERATOR        3       ps_trace.%=  ,
                OPERATOR        4       ps_trace.%>= ,
                OPERATOR        5       ps_trace.%>  ,
                FUNCTION        1       _ps_trace.tag_v_cmp(_ps_trace.tag_v, _ps_trace.tag_v);
EXCEPTION
    WHEN SQLSTATE '42710' THEN -- object already exists
        EXECUTE format($q$ALTER OPERATOR CLASS ps_trace.btree_tag_v_ops USING btree OWNER TO %I$q$, current_user);
        EXECUTE format($q$ALTER OPERATOR FAMILY ps_trace.btree_tag_v_ops USING btree OWNER TO %I$q$, current_user);
END;
$do$;
