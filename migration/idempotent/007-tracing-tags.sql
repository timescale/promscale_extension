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

-------------------------------------------------------------------------------
-- the -> operator
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ps_trace.tag_map_object_field(ps_trace.tag_map, pg_catalog.text)
    RETURNS _ps_trace.tag_v
    STRICT
    LANGUAGE internal AS 'jsonb_object_field';
GRANT EXECUTE ON FUNCTION ps_trace.tag_map_object_field(ps_trace.tag_map, pg_catalog.text) TO prom_reader;

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

CREATE OR REPLACE FUNCTION ps_trace.tag_v_eq(_ps_trace.tag_v, _ps_trace.tag_v)
    RETURNS pg_catalog.bool
    LANGUAGE internal
        IMMUTABLE
        STRICT
        PARALLEL SAFE
    AS 'jsonb_eq';
GRANT EXECUTE ON FUNCTION ps_trace.tag_v_eq(_ps_trace.tag_v, _ps_trace.tag_v) TO prom_reader;

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


DO $do$
BEGIN
	CREATE OPERATOR ps_trace.= (
	    FUNCTION       = ps_trace.tag_v_eq,
	    LEFTARG        = _ps_trace.tag_v,
	    RIGHTARG       = _ps_trace.tag_v,
        NEGATOR        = OPERATOR(ps_trace.<>),
	    RESTRICT       = eqsel,
	    JOIN           = eqjoinsel,
	    HASHES, MERGES
	);
EXCEPTION
    WHEN SQLSTATE '42723' THEN -- operator already exists
        EXECUTE format($q$ALTER OPERATOR ps_trace.=(_ps_trace.tag_v, _ps_trace.tag_v) OWNER TO %I$q$, current_user);
END;
$do$;
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

CREATE OR REPLACE FUNCTION ps_trace.tag_v_ne(_ps_trace.tag_v, _ps_trace.tag_v)
    RETURNS pg_catalog.bool
    LANGUAGE internal
        IMMUTABLE
        STRICT
        PARALLEL SAFE
    AS 'jsonb_ne';
GRANT EXECUTE ON FUNCTION ps_trace.tag_v_ne(_ps_trace.tag_v, _ps_trace.tag_v) TO prom_reader;


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

DO $do$
BEGIN
	CREATE OPERATOR ps_trace.<> (
	    FUNCTION       = ps_trace.tag_v_ne,
	    LEFTARG        = _ps_trace.tag_v,
	    RIGHTARG       = _ps_trace.tag_v,
	    NEGATOR        = OPERATOR(ps_trace.=),
	    RESTRICT       = neqsel,
	    JOIN           = neqjoinsel
	);
EXCEPTION
    WHEN SQLSTATE '42723' THEN -- operator already exists
        EXECUTE format($q$ALTER OPERATOR ps_trace.<>(_ps_trace.tag_v, _ps_trace.tag_v) OWNER TO %I$q$, current_user);
END;
$do$;

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

CREATE OR REPLACE FUNCTION ps_trace.tag_v_gt(_ps_trace.tag_v, _ps_trace.tag_v)
    RETURNS pg_catalog.bool
    LANGUAGE internal
        IMMUTABLE
        STRICT
        PARALLEL SAFE
    AS 'jsonb_gt';
GRANT EXECUTE ON FUNCTION ps_trace.tag_v_gt(_ps_trace.tag_v, _ps_trace.tag_v) TO prom_reader;

CREATE OR REPLACE FUNCTION ps_trace.tag_v_ge(_ps_trace.tag_v, _ps_trace.tag_v)
    RETURNS pg_catalog.bool
    LANGUAGE internal
        IMMUTABLE
        STRICT
        PARALLEL SAFE
    AS 'jsonb_ge';
GRANT EXECUTE ON FUNCTION ps_trace.tag_v_ge(_ps_trace.tag_v, _ps_trace.tag_v) TO prom_reader;

CREATE OR REPLACE FUNCTION ps_trace.tag_v_lt(_ps_trace.tag_v, _ps_trace.tag_v)
    RETURNS pg_catalog.bool
    LANGUAGE internal
        IMMUTABLE
        STRICT
        PARALLEL SAFE
    AS 'jsonb_lt';
GRANT EXECUTE ON FUNCTION ps_trace.tag_v_lt(_ps_trace.tag_v, _ps_trace.tag_v) TO prom_reader;

CREATE OR REPLACE FUNCTION ps_trace.tag_v_le(_ps_trace.tag_v, _ps_trace.tag_v)
    RETURNS pg_catalog.bool
    LANGUAGE internal
        IMMUTABLE
        STRICT
        PARALLEL SAFE
    AS 'jsonb_le';
GRANT EXECUTE ON FUNCTION ps_trace.tag_v_le(_ps_trace.tag_v, _ps_trace.tag_v) TO prom_reader;

DO $do$
BEGIN
	CREATE OPERATOR ps_trace.> (
	    FUNCTION       = ps_trace.tag_v_gt,
	    LEFTARG        = _ps_trace.tag_v,
	    RIGHTARG       = _ps_trace.tag_v,
	    NEGATOR        = OPERATOR(ps_trace.<=),
	    RESTRICT       = scalargtsel,
	    JOIN           = scalargtjoinsel
	);
EXCEPTION
    WHEN SQLSTATE '42723' THEN -- operator already exists
        EXECUTE format($q$ALTER OPERATOR ps_trace.>(_ps_trace.tag_v, _ps_trace.tag_v) OWNER TO %I$q$, current_user);
END;
$do$;


DO $do$
BEGIN
	CREATE OPERATOR ps_trace.>= (
	    FUNCTION       = ps_trace.tag_v_ge,
	    LEFTARG        = _ps_trace.tag_v,
	    RIGHTARG       = _ps_trace.tag_v,
	    NEGATOR        = OPERATOR(ps_trace.<),
	    RESTRICT       = scalargesel,
	    JOIN           = scalargejoinsel
	);
EXCEPTION
    WHEN SQLSTATE '42723' THEN -- operator already exists
        EXECUTE format($q$ALTER OPERATOR ps_trace.>=(_ps_trace.tag_v, _ps_trace.tag_v) OWNER TO %I$q$, current_user);
END;
$do$;

DO $do$
BEGIN
	CREATE OPERATOR ps_trace.< (
	    FUNCTION       = ps_trace.tag_v_lt,
	    LEFTARG        = _ps_trace.tag_v,
	    RIGHTARG       = _ps_trace.tag_v,
	    NEGATOR        = OPERATOR(ps_trace.>=),
	    RESTRICT       = scalarltsel,
	    JOIN           = scalarltjoinsel
	);
EXCEPTION
    WHEN SQLSTATE '42723' THEN -- operator already exists
        EXECUTE format($q$ALTER OPERATOR ps_trace.<(_ps_trace.tag_v, _ps_trace.tag_v) OWNER TO %I$q$, current_user);
END;
$do$;


DO $do$
BEGIN
	CREATE OPERATOR ps_trace.<= (
	    FUNCTION       = ps_trace.tag_v_le,
	    LEFTARG        = _ps_trace.tag_v,
	    RIGHTARG       = _ps_trace.tag_v,
	    NEGATOR        = OPERATOR(ps_trace.>),
	    RESTRICT       = scalarlesel,
	    JOIN           = scalarlejoinsel
	);
EXCEPTION
    WHEN SQLSTATE '42723' THEN -- operator already exists
        EXECUTE format($q$ALTER OPERATOR ps_trace.<=(_ps_trace.tag_v, _ps_trace.tag_v) OWNER TO %I$q$, current_user);
END;
$do$;



/* Create opclass for tag_v for distinct/group by type of queries */

DO $do$
BEGIN
    CREATE OPERATOR CLASS btree_tag_v_ops
    DEFAULT FOR TYPE _ps_trace.tag_v USING btree
    AS
            OPERATOR        1       ps_trace.<  ,
            OPERATOR        2       ps_trace.<= ,
            OPERATOR        3       ps_trace.=  ,
            OPERATOR        4       ps_trace.>= ,
            OPERATOR        5       ps_trace.>  ,
            FUNCTION        1       _ps_trace.tag_v_cmp(_ps_trace.tag_v, _ps_trace.tag_v);
EXCEPTION
    WHEN SQLSTATE '42710' THEN -- object already exists
        EXECUTE format($q$ALTER OPERATOR CLASS public.btree_tag_v_ops USING btree OWNER TO %I$q$, current_user);
END;
$do$;
