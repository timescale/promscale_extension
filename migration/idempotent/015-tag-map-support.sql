CREATE AGGREGATE ps_trace.jsonb_cat(pg_catalog.jsonb)
(
    SFUNC = pg_catalog.jsonb_concat,
    STYPE = pg_catalog.jsonb
);

CREATE FUNCTION ps_trace.tag_v_eq(ps_trace.tag_v, pg_catalog.jsonb)
    RETURNS pg_catalog.bool
    LANGUAGE internal
        IMMUTABLE
        PARALLEL SAFE
        SUPPORT _prom_ext.tag_map_rewrite
    AS 'jsonb_eq';

CREATE FUNCTION _ps_trace.tag_v_eq_rewrite_helper(_tag_key pg_catalog.text, _value pg_catalog.jsonb)
    RETURNS pg_catalog.jsonb
    LANGUAGE sql STABLE
    PARALLEL SAFE AS
$fnc$
    SELECT pg_catalog.jsonb_build_object(a.key_id, a.id)
    FROM _ps_trace.tag a
    WHERE a.key = _tag_key
    AND _prom_ext.jsonb_digest(a.value) = _prom_ext.jsonb_digest(_value)
    AND a.value = _value
    LIMIT 1
$fnc$;

CREATE FUNCTION ps_trace.tag_v_ne(ps_trace.tag_v, pg_catalog.jsonb)
    RETURNS pg_catalog.bool
    LANGUAGE internal
        IMMUTABLE
        PARALLEL SAFE
        SUPPORT _prom_ext.tag_map_rewrite
    AS 'jsonb_ne';

CREATE FUNCTION _ps_trace.tag_v_ne_rewrite_helper(_tag_key pg_catalog.text, _value pg_catalog.jsonb)
    RETURNS pg_catalog.jsonb[]
    LANGUAGE sql STABLE
    PARALLEL SAFE AS
$fnc$
    SELECT coalesce(pg_catalog.array_agg(pg_catalog.jsonb_build_object(a.key_id, a.id)), array[]::jsonb[])
    FROM _ps_trace.tag a
    WHERE a.key = _tag_key
    AND a.value != _value
$fnc$;
