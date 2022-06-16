
-------------------------------------------------------------------------------
-- tag type functions
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ps_trace.span_tag_type()
RETURNS ps_trace.tag_type
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $sql$
    SELECT (1 OPERATOR(pg_catalog.<<) 0)::smallint::ps_trace.tag_type
$sql$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION ps_trace.span_tag_type() TO prom_reader;
COMMENT ON FUNCTION ps_trace.span_tag_type
IS 'This function returns tag_type with the span tag bit.';

CREATE OR REPLACE FUNCTION ps_trace.resource_tag_type()
RETURNS ps_trace.tag_type
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $sql$
    SELECT (1 OPERATOR(pg_catalog.<<) 1)::smallint::ps_trace.tag_type
$sql$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION ps_trace.resource_tag_type() TO prom_reader;
COMMENT ON FUNCTION ps_trace.resource_tag_type
IS 'This function returns tag_type with the resource tag bit.';

CREATE OR REPLACE FUNCTION ps_trace.event_tag_type()
RETURNS ps_trace.tag_type
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $sql$
    SELECT (1 OPERATOR(pg_catalog.<<) 2)::smallint::ps_trace.tag_type
$sql$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION ps_trace.event_tag_type() TO prom_reader;
COMMENT ON FUNCTION ps_trace.event_tag_type 
IS 'This function returns tag_type with the event tag bit.';

CREATE OR REPLACE FUNCTION ps_trace.link_tag_type()
RETURNS ps_trace.tag_type
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $sql$
    SELECT (1 OPERATOR(pg_catalog.<<) 3)::smallint::ps_trace.tag_type
$sql$
LANGUAGE SQL IMMUTABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION ps_trace.link_tag_type() TO prom_reader;
COMMENT ON FUNCTION ps_trace.link_tag_type
IS 'This function returns tag_type with the link tag bit.';

CREATE OR REPLACE FUNCTION ps_trace.is_span_tag_type(_tag_type ps_trace.tag_type)
RETURNS BOOLEAN
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $sql$
    SELECT _tag_type OPERATOR(pg_catalog.&) ps_trace.span_tag_type() OPERATOR(pg_catalog.=) ps_trace.span_tag_type()
$sql$
LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION ps_trace.is_span_tag_type(ps_trace.tag_type) TO prom_reader;
COMMENT ON FUNCTION ps_trace.is_span_tag_type
IS 'This function checks whether a tag_type value has the span tag bit set.';

CREATE OR REPLACE FUNCTION ps_trace.is_resource_tag_type(_tag_type ps_trace.tag_type)
RETURNS BOOLEAN
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $sql$
    SELECT _tag_type OPERATOR(pg_catalog.&) ps_trace.resource_tag_type() OPERATOR(pg_catalog.=) ps_trace.resource_tag_type()
$sql$
LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION ps_trace.is_resource_tag_type(ps_trace.tag_type) TO prom_reader;
COMMENT ON FUNCTION ps_trace.is_resource_tag_type
IS 'This function checks whether a tag_type value has the resource tag bit set.';

CREATE OR REPLACE FUNCTION ps_trace.is_event_tag_type(_tag_type ps_trace.tag_type)
RETURNS BOOLEAN
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $sql$
    SELECT _tag_type OPERATOR(pg_catalog.&) ps_trace.event_tag_type() OPERATOR(pg_catalog.=) ps_trace.event_tag_type()
$sql$
LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION ps_trace.is_event_tag_type(ps_trace.tag_type) TO prom_reader;
COMMENT ON FUNCTION ps_trace.is_event_tag_type
IS 'This function checks whether a tag_type value has the event tag bit set.';

CREATE OR REPLACE FUNCTION ps_trace.is_link_tag_type(_tag_type ps_trace.tag_type)
RETURNS BOOLEAN
-- Note: no explicit `SET SCHEMA` because we want this function to be inlined
AS $sql$
    SELECT _tag_type OPERATOR(pg_catalog.&) ps_trace.link_tag_type() OPERATOR(pg_catalog.=) ps_trace.link_tag_type()
$sql$
LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION ps_trace.is_link_tag_type(ps_trace.tag_type) TO prom_reader;
COMMENT ON FUNCTION ps_trace.is_link_tag_type
IS 'This function checks whether a tag_type value has the link tag bit set.';

-------------------------------------------------------------------------------
-- trace tree functions
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ps_trace.trace_tree(_trace_id ps_trace.trace_id)
RETURNS TABLE
(
    trace_id ps_trace.trace_id,
    parent_span_id bigint,
    span_id bigint,
    lvl int,
    path bigint[]
)
SET search_path = pg_catalog, pg_temp
AS $func$
        WITH RECURSIVE x as
    (
        SELECT
            s1.parent_span_id,
            s1.span_id,
            1 as lvl,
            array[s1.span_id] as path
        FROM _ps_trace.span s1
        WHERE s1.trace_id OPERATOR(ps_trace.=) _trace_id
        AND s1.parent_span_id IS NULL
        UNION ALL
        SELECT
            s2.parent_span_id,
            s2.span_id,
            x.lvl + 1 as lvl,
            x.path || s2.span_id as path
        FROM x
        INNER JOIN LATERAL
        (
            SELECT
                s2.parent_span_id,
                s2.span_id
            FROM _ps_trace.span s2
            WHERE s2.trace_id OPERATOR(ps_trace.=) _trace_id
            AND s2.parent_span_id = x.span_id
        ) s2 ON (true)
    )
    SELECT
        _trace_id,
        x.parent_span_id,
        x.span_id,
        x.lvl,
        x.path
    FROM x
$func$ LANGUAGE sql STABLE STRICT PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION ps_trace.trace_tree(ps_trace.trace_id) TO prom_reader;
COMMENT ON FUNCTION ps_trace.trace_tree
IS 'This function returns a set of all spans for a given trace_id. Additionally, parent span,
nesting level and a path (as an array of span_id) are supplied for each span in the set.';

CREATE OR REPLACE FUNCTION ps_trace.upstream_spans(_trace_id ps_trace.trace_id, _span_id bigint, _max_dist int default null)
RETURNS TABLE
(
    trace_id ps_trace.trace_id,
    parent_span_id bigint,
    span_id bigint,
    dist int,
    path bigint[]
)
SET search_path = pg_catalog, pg_temp
AS $func$
    WITH RECURSIVE x as
    (
        SELECT
          s1.parent_span_id,
          s1.span_id,
          0 as dist,
          array[s1.span_id] as path
        FROM _ps_trace.span s1
        WHERE s1.trace_id OPERATOR(ps_trace.=) _trace_id
        AND s1.span_id = _span_id
        UNION ALL
        SELECT
          s2.parent_span_id,
          s2.span_id,
          x.dist + 1 as dist,
          s2.span_id || x.path as path
        FROM x
        INNER JOIN LATERAL
        (
            SELECT
                s2.parent_span_id,
                s2.span_id
            FROM _ps_trace.span s2
            WHERE s2.trace_id OPERATOR(ps_trace.=) _trace_id
            AND s2.span_id = x.parent_span_id
        ) s2 ON (true)
        WHERE (_max_dist IS NULL OR x.dist + 1 <= _max_dist)
    )
    SELECT
        _trace_id,
        x.parent_span_id,
        x.span_id,
        x.dist,
        x.path
    FROM x
$func$ LANGUAGE sql STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION ps_trace.upstream_spans(ps_trace.trace_id, bigint, int) TO prom_reader;
COMMENT ON FUNCTION ps_trace.upstream_spans
IS 'For a given trace_id and span_id this function returns a set that consists of the all spans starting
from the specified span and up to the root of the trace. Each span is annotated with parent_span_id,
a distance from the specified span (the span itself has the distance of 0) and a path from the specified span 
towards the root. Optional third argument allows to limit the span tree traversal to a certain distance from 
the specified span_id.';

CREATE OR REPLACE FUNCTION ps_trace.downstream_spans(_trace_id ps_trace.trace_id, _span_id bigint, _max_dist int default null)
RETURNS TABLE
(
    trace_id ps_trace.trace_id,
    parent_span_id bigint,
    span_id bigint,
    dist int,
    path bigint[]
)
SET search_path = pg_catalog, pg_temp
AS $func$
    WITH RECURSIVE x as
    (
        SELECT
          s1.parent_span_id,
          s1.span_id,
          0 as dist,
          array[s1.span_id] as path
        FROM _ps_trace.span s1
        WHERE s1.trace_id OPERATOR(ps_trace.=) _trace_id
        AND s1.span_id = _span_id
        UNION ALL
        SELECT
          s2.parent_span_id,
          s2.span_id,
          x.dist + 1 as dist,
          x.path || s2.span_id as path
        FROM x
        INNER JOIN LATERAL
        (
            SELECT *
            FROM _ps_trace.span s2
            WHERE s2.trace_id OPERATOR(ps_trace.=) _trace_id
            AND s2.parent_span_id = x.span_id
        ) s2 ON (true)
        WHERE (_max_dist IS NULL OR x.dist + 1 <= _max_dist)
    )
    SELECT
        _trace_id,
        x.parent_span_id,
        x.span_id,
        x.dist,
        x.path
    FROM x
$func$ LANGUAGE sql STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION ps_trace.downstream_spans(ps_trace.trace_id, bigint, int) TO prom_reader;
COMMENT ON FUNCTION ps_trace.downstream_spans
IS 'For a given trace_id and span_id this function returns a set that consists of the all spans starting
from the specified span and down to the leaves of the trace. Each span is annotated with parent_span_id,
a distance from the specified span (the span itself has the distance of 0) and a path from the specified span 
towards the root. Optional third argument allows to limit the span tree traversal to a certain distance from 
the specified span_id.';

CREATE OR REPLACE FUNCTION ps_trace.sibling_spans(_trace_id ps_trace.trace_id, _span_id bigint)
RETURNS TABLE
(
    trace_id ps_trace.trace_id,
    parent_span_id bigint,
    span_id bigint
)
SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT
        _trace_id,
        s.parent_span_id,
        s.span_id
    FROM _ps_trace.span s
    WHERE s.trace_id OPERATOR(ps_trace.=) _trace_id
    AND s.parent_span_id =
    (
        SELECT parent_span_id
        FROM _ps_trace.span x
        WHERE x.trace_id OPERATOR(ps_trace.=) _trace_id
        AND x.span_id = _span_id
    )
$func$ LANGUAGE sql STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION ps_trace.sibling_spans(ps_trace.trace_id, bigint) TO prom_reader;
COMMENT ON FUNCTION ps_trace.sibling_spans
IS 'For a given trace_id and span_id this function returns spans sharing the same parent_span_id.';

CREATE OR REPLACE FUNCTION ps_trace.operation_calls(_start_time_min timestamptz, _start_time_max timestamptz)
RETURNS TABLE
(
    parent_operation_id bigint,
    child_operation_id bigint,
    cnt bigint
)
SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT
        parent.operation_id as parent_operation_id,
        child.operation_id as child_operation_id,
        count(*) as cnt
    FROM
        _ps_trace.span child
    INNER JOIN
        _ps_trace.span parent ON (parent.span_id = child.parent_span_id AND parent.trace_id OPERATOR(ps_trace.=) child.trace_id)
    WHERE
        child.start_time > _start_time_min AND child.start_time < _start_time_max AND
        parent.start_time > _start_time_min AND parent.start_time < _start_time_max
    GROUP BY parent.operation_id, child.operation_id
$func$ LANGUAGE sql
--Always prefer a mergejoin here since this is a rollup over a lot of data.
--a nested loop is sometimes preferred by the planner but is almost never right
--(it may only be right in cases where there is not a lot of data, and then it does
-- not matter)
SET  enable_nestloop = off
STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION ps_trace.operation_calls(timestamptz, timestamptz) TO prom_reader;
COMMENT ON FUNCTION ps_trace.operation_calls
IS 'This function counts the number of parent -> child pairs (aka calls) within a specified
time window and their operation ids.';

CREATE OR REPLACE FUNCTION ps_trace.span_tree(_trace_id ps_trace.trace_id, _span_id bigint, _max_dist int default null)
RETURNS TABLE
(
    trace_id ps_trace.trace_id,
    parent_span_id bigint,
    span_id bigint,
    dist int,
    is_upstream bool,
    is_downstream bool,
    path bigint[]
)
SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT
        trace_id,
        parent_span_id,
        span_id,
        dist,
        true as is_upstream,
        false as is_downstream,
        path
    FROM ps_trace.upstream_spans(_trace_id, _span_id, _max_dist) u
    WHERE u.dist != 0
    UNION ALL
    SELECT
        trace_id,
        parent_span_id,
        span_id,
        dist,
        false as is_upstream,
        dist != 0 as is_downstream,
        path
    FROM ps_trace.downstream_spans(_trace_id, _span_id, _max_dist) d
$func$ LANGUAGE sql STABLE PARALLEL SAFE;
GRANT EXECUTE ON FUNCTION ps_trace.span_tree(ps_trace.trace_id, bigint, int) TO prom_reader;
COMMENT ON FUNCTION ps_trace.span_tree
IS 'For a given pair of trace_id and span_id, this function returns a union of
downstream_spans and upstream_spans.';

-------------------------------------------------------------------------------
-- get / put functions
-------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ps_trace.put_tag_key(_key ps_trace.tag_k, _tag_type ps_trace.tag_type)
    RETURNS bigint
    VOLATILE STRICT
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
    _tag_key _ps_trace.tag_key;
BEGIN
    SELECT * INTO _tag_key
    FROM _ps_trace.tag_key k
    WHERE k.key = _key
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO _ps_trace.tag_key as k (key, tag_type)
        VALUES (_key, _tag_type)
        ON CONFLICT (key) DO
        UPDATE SET tag_type = k.tag_type | EXCLUDED.tag_type
        WHERE k.tag_type & EXCLUDED.tag_type = 0;

        SELECT * INTO STRICT _tag_key
        FROM _ps_trace.tag_key k
        WHERE k.key = _key;
    ELSIF _tag_key.tag_type & _tag_type = 0 THEN
        UPDATE _ps_trace.tag_key k
        SET tag_type = k.tag_type | _tag_type
        WHERE k.id = _tag_key.id;
    END IF;

    RETURN _tag_key.id;
END;
$func$
LANGUAGE plpgsql;
GRANT EXECUTE ON FUNCTION ps_trace.put_tag_key(ps_trace.tag_k, ps_trace.tag_type) TO prom_writer;
COMMENT ON FUNCTION ps_trace.put_tag_key
IS 'This function creates a new tag key and associates it with the specified tag type and returns
its id (a key in _ps_trace.tag_key table)';

CREATE OR REPLACE FUNCTION ps_trace.put_tag(_key ps_trace.tag_k, _value _ps_trace.tag_v, _tag_type ps_trace.tag_type)
    RETURNS BIGINT
    VOLATILE STRICT
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
    _tag _ps_trace.tag;
    _value_digest bytea;
BEGIN
    SELECT _prom_ext.jsonb_digest(_value) INTO _value_digest;

    SELECT * INTO _tag
    FROM _ps_trace.tag
    WHERE key = _key
    AND _prom_ext.jsonb_digest(value) = _value_digest
    AND value = _value
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO _ps_trace.tag as t (tag_type, key_id, key, value)
        SELECT
            _tag_type,
            k.id,
            _key,
            _value
        FROM _ps_trace.tag_key k
        WHERE k.key = _key
        ON CONFLICT (key, _prom_ext.jsonb_digest(value)) DO
        UPDATE SET tag_type = t.tag_type | EXCLUDED.tag_type
        WHERE t.tag_type & EXCLUDED.tag_type = 0;

        SELECT * INTO STRICT _tag
        FROM _ps_trace.tag
        WHERE key = _key
        AND _prom_ext.jsonb_digest(value) = _value_digest
        AND value = _value;
    ELSIF _tag.tag_type & _tag_type = 0 THEN
        UPDATE _ps_trace.tag as t
        SET tag_type = t.tag_type | _tag_type
        WHERE t.key = _key -- partition elimination
        AND t.id = _tag.id;
    END IF;

    IF _tag.value != _value THEN
        RAISE EXCEPTION 'put_tag failed. Distinct values % and % for key % have identical sha512 digest.', _tag.value, _value, _key;
    END IF;

    RETURN _tag.id;
END;
$func$
LANGUAGE plpgsql;
GRANT EXECUTE ON FUNCTION ps_trace.put_tag(ps_trace.tag_k, _ps_trace.tag_v, ps_trace.tag_type) TO prom_writer;
COMMENT ON FUNCTION ps_trace.put_tag
IS 'This function inserts a new tag with the specified value and returns its id (a key in _ps_trace.tag table).
The specified tag key must exist for the specified resource type.';

CREATE OR REPLACE FUNCTION ps_trace.get_tag_map(_tags jsonb)
RETURNS ps_trace.tag_map
SET search_path = pg_catalog, pg_temp
AS $func$
    SELECT coalesce(jsonb_object_agg(a.key_id, a.id), '{}')::ps_trace.tag_map
    FROM jsonb_each(_tags) x
    INNER JOIN LATERAL
    (
        SELECT a.key_id, a.id
        FROM _ps_trace.tag a
        WHERE x.key = a.key
        AND _prom_ext.jsonb_digest(x.value) = _prom_ext.jsonb_digest(a.value)
        AND x.value = a.value
        LIMIT 1
    ) a on (true)
$func$
LANGUAGE SQL STABLE PARALLEL SAFE STRICT;
GRANT EXECUTE ON FUNCTION ps_trace.get_tag_map(jsonb) TO prom_reader;
COMMENT ON FUNCTION ps_trace.get_tag_map
IS 'For a given jsonb object cosisting of key-value pairs, representing tags and their values,
this funciton returns a jsonb object of corresponding ids -- the primary keys in
_ps_trace.tag_key and _ps_trace.tag tables.';

CREATE OR REPLACE FUNCTION ps_trace.put_operation(_service_name text, _span_name text, _span_kind ps_trace.span_kind)
    RETURNS bigint
    VOLATILE STRICT
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
    _service_name_id bigint;
    _operation_id bigint;
    _service_name_json jsonb;
    _service_name_digest bytea;
BEGIN
    SELECT to_jsonb(_service_name::text) INTO _service_name_json;
    SELECT _prom_ext.jsonb_digest(_service_name_json) INTO _service_name_digest;

    SELECT id INTO _service_name_id
    FROM _ps_trace.tag
    WHERE key = 'service.name'
    AND key_id = 1
    AND _prom_ext.jsonb_digest(value) = _service_name_digest
    AND value = _service_name_json
    ;

    IF NOT FOUND THEN
        INSERT INTO _ps_trace.tag (tag_type, key, key_id, value)
        VALUES
        (
            ps_trace.resource_tag_type(),
            'service.name',
            1,
            _service_name_json
        )
        ON CONFLICT DO NOTHING
        RETURNING id INTO _service_name_id;

        IF _service_name_id IS NULL THEN
            SELECT id INTO STRICT _service_name_id
            FROM _ps_trace.tag
            WHERE key = 'service.name'
            AND key_id = 1
            AND _prom_ext.jsonb_digest(value) = _service_name_digest
            AND value = _service_name_json;
        END IF;
    END IF;

    SELECT id INTO _operation_id
    FROM _ps_trace.operation
    WHERE service_name_id = _service_name_id
    AND span_kind = _span_kind
    AND span_name = _span_name;

    IF NOT FOUND THEN
        INSERT INTO _ps_trace.operation (service_name_id, span_kind, span_name)
        VALUES
        (
            _service_name_id,
            _span_kind,
            _span_name
        )
        ON CONFLICT DO NOTHING
        RETURNING id INTO _operation_id;

        IF _operation_id IS NULL THEN
            SELECT id INTO STRICT _operation_id
            FROM _ps_trace.operation
            WHERE service_name_id = _service_name_id
            AND span_kind = _span_kind
            AND span_name = _span_name;
        END IF;
    END IF;

    RETURN _operation_id;
END;
$func$
LANGUAGE plpgsql;
GRANT EXECUTE ON FUNCTION ps_trace.put_operation(text, text, ps_trace.span_kind) TO prom_writer;
COMMENT ON FUNCTION ps_trace.put_operation
IS 'This function creates an operation record and a necessary service.name tag, if either doesn''t exist 
and returns the operation''s id (a key in the _ps_tag.opertaions table). It is meant to be used during
span creation, to obtain a valid value for mandatory operation_id attribute.';

CREATE OR REPLACE FUNCTION ps_trace.put_schema_url(_schema_url text)
    RETURNS bigint
    VOLATILE STRICT
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
    _schema_url_id bigint;
BEGIN
    SELECT id INTO _schema_url_id
    FROM _ps_trace.schema_url
    WHERE url = _schema_url;

    IF NOT FOUND THEN
        INSERT INTO _ps_trace.schema_url (url)
        VALUES (_schema_url)
        ON CONFLICT DO NOTHING
        RETURNING id INTO _schema_url_id;

        IF _schema_url_id IS NULL THEN
            SELECT id INTO STRICT _schema_url_id
            FROM _ps_trace.schema_url
            WHERE url = _schema_url;
        END IF;
    END IF;

    RETURN _schema_url_id;
END;
$func$
LANGUAGE plpgsql;
GRANT EXECUTE ON FUNCTION ps_trace.put_schema_url(text) TO prom_writer;
COMMENT ON FUNCTION ps_trace.put_schema_url
IS 'This function creates an entry in the _ps_trace.schema_url table if it doesn''t exit and returns its id.
It is meant to be used during span creation, to obtain a valid value for mandatory resource_schema_url_id attribute.';

CREATE OR REPLACE FUNCTION ps_trace.put_instrumentation_lib(_name text, _version text, _schema_url_id bigint)
    RETURNS bigint
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
DECLARE
    _inst_lib_id bigint;
BEGIN
    SELECT id INTO _inst_lib_id
    FROM _ps_trace.instrumentation_lib
    WHERE name = _name
    AND version = _version
    AND schema_url_id = _schema_url_id;

    IF NOT FOUND THEN
        INSERT INTO _ps_trace.instrumentation_lib (name, version, schema_url_id)
        VALUES
        (
            _name,
            _version,
            _schema_url_id
        )
        ON CONFLICT DO NOTHING
        RETURNING id INTO _inst_lib_id;

        IF _inst_lib_id IS NULL THEN
            SELECT id INTO STRICT _inst_lib_id
            FROM _ps_trace.instrumentation_lib
            WHERE name = _name
            AND version = _version
            AND schema_url_id = _schema_url_id;
        END IF;
    END IF;

    RETURN _inst_lib_id;
END;
$func$
LANGUAGE plpgsql;
GRANT EXECUTE ON FUNCTION ps_trace.put_instrumentation_lib(text, text, bigint) TO prom_writer;
COMMENT ON FUNCTION ps_trace.put_instrumentation_lib
IS 'This function creates an entry in the _ps_trace.instrumentation_lib table if it doesn''t exit and returns its id.
It is meant to be used during span creation, to obtain a valid value for mandatory instrumentation_lib_id attribute.';

-- Creates a temporary table (if it doesn't exist), suitable for tracing data ingestion.
-- Supresses corresponding DDL logging, otherwise PG log may get unnecessarily verbose.
CREATE OR REPLACE FUNCTION _ps_trace.ensure_trace_ingest_temp_table(_temp_table_name text, _proto_table_name text)
    RETURNS void
    SECURITY DEFINER
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
BEGIN
    IF _proto_table_name NOT IN ('span', 'link', 'event') THEN
        RAISE EXCEPTION 'Invalid table prototype specified: %', _proto_table_name;
    END IF;

    SET LOCAL log_statement = 'none';

    EXECUTE format($sql$CREATE TEMPORARY TABLE IF NOT EXISTS %I (LIKE _ps_trace.%I) ON COMMIT DELETE ROWS$sql$,
                    _temp_table_name, _proto_table_name);
    EXECUTE format($sql$GRANT SELECT, INSERT ON TABLE %I TO prom_writer$sql$,
                    _temp_table_name);
END;
$func$
LANGUAGE plpgsql;
REVOKE ALL ON FUNCTION _ps_trace.ensure_trace_ingest_temp_table(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION _ps_trace.ensure_trace_ingest_temp_table(text, text) TO prom_writer;
COMMENT ON FUNCTION _ps_trace.ensure_trace_ingest_temp_table
IS 'Creates a temporary table (if it doesn''t exist), suitable for tracing data ingestion. 
Supresses corresponding DDL logging, otherwise PG log may get unnecessarily verbose.';

CREATE OR REPLACE FUNCTION ps_trace.delete_all_traces()
    RETURNS void
    SECURITY DEFINER
    VOLATILE
    SET search_path = pg_catalog, pg_temp
AS $func$
    TRUNCATE _ps_trace.link;
    TRUNCATE _ps_trace.event;
    TRUNCATE _ps_trace.span;
    TRUNCATE _ps_trace.instrumentation_lib RESTART IDENTITY;
    TRUNCATE _ps_trace.operation RESTART IDENTITY;
    TRUNCATE _ps_trace.schema_url RESTART IDENTITY CASCADE;
    TRUNCATE _ps_trace.tag RESTART IDENTITY;
    DELETE FROM _ps_trace.tag_key WHERE id >= 1000; -- keep the "standard" tag keys
    SELECT setval('_ps_trace.tag_key_id_seq', 1000);
$func$
LANGUAGE sql;
GRANT EXECUTE ON FUNCTION ps_trace.delete_all_traces() TO prom_admin;
COMMENT ON FUNCTION ps_trace.delete_all_traces
IS 'WARNING: this function deletes all spans and related tracing data in the system and restores
it to a "just installed" state.';

CREATE OR REPLACE FUNCTION ps_trace.tag_map_in(cstring)
RETURNS ps_trace.tag_map
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$jsonb_in$function$
;
COMMENT ON FUNCTION ps_trace.tag_map_in
IS 'This function is a part of custom ps_trace.tag_map type which is a wrapper for the built-in jsonb. It is the same as its jsonb_ namesake.';

CREATE OR REPLACE FUNCTION ps_trace.tag_map_out(ps_trace.tag_map)
RETURNS cstring
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$jsonb_out$function$
;
COMMENT ON FUNCTION ps_trace.tag_map_out
IS 'This function is a part of custom ps_trace.tag_map type which is a wrapper for the built-in jsonb. It is the same as its jsonb_ namesake.';

CREATE OR REPLACE FUNCTION ps_trace.tag_map_send(ps_trace.tag_map)
RETURNS bytea
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$jsonb_send$function$
;
COMMENT ON FUNCTION ps_trace.tag_map_send
IS 'This function is a part of custom ps_trace.tag_map type which is a wrapper for the built-in jsonb. It is the same as its jsonb_ namesake.';

CREATE OR REPLACE FUNCTION ps_trace.tag_map_recv(internal)
RETURNS ps_trace.tag_map
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$jsonb_recv$function$
;
COMMENT ON FUNCTION ps_trace.tag_map_recv
IS 'This function is a part of custom ps_trace.tag_map type which is a wrapper for the built-in jsonb. It is the same as its jsonb_ namesake.';

DO
$do$

/* Create subscript_handler function for pg v14+.
 * For pg v13 jsonb type doesn't have a subscript_handler function so it shall
 * be omitted.
 */
DECLARE
    _pg_version int4 := current_setting('server_version_num')::int4;
BEGIN
    IF (_pg_version >= 140000) THEN
        CREATE OR REPLACE FUNCTION ps_trace.tag_map_subscript_handler(internal)
                RETURNS internal
                LANGUAGE internal
                IMMUTABLE PARALLEL SAFE STRICT
                AS $f$jsonb_subscript_handler$f$;

        COMMENT ON FUNCTION ps_trace.tag_map_subscript_handler
        IS 'This function is a part of custom ps_trace.tag_map type which is a wrapper for the built-in jsonb. It is the same as its jsonb_ namesake.';
        /* Add subscript handler in case of a prior PG13 -> PG14 upgrade that
         * didn't take care of this
         */
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_type
            WHERE typname      = 'tag_map'
              AND typnamespace = 'ps_trace'::regnamespace
              AND typsubscript = 'ps_trace.tag_map_subscript_handler'::regproc
            ) THEN
                ALTER TYPE ps_trace.tag_map SET (SUBSCRIPT = ps_trace.tag_map_subscript_handler);
        END IF;
    END IF;
END
$do$;

CREATE OR REPLACE FUNCTION _ps_trace.tag_v_in(cstring)
RETURNS _ps_trace.tag_v
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$jsonb_in$function$
;
COMMENT ON FUNCTION _ps_trace.tag_v_in
IS 'This function is a part of custom _ps_trace.tag_v type which is a wrapper for the built-in jsonb. It is the same as its jsonb_ namesake.';

CREATE OR REPLACE FUNCTION _ps_trace.tag_v_out(_ps_trace.tag_v)
RETURNS cstring
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$jsonb_out$function$
;
COMMENT ON FUNCTION _ps_trace.tag_v_out
IS 'This function is a part of custom _ps_trace.tag_v type which is a wrapper for the built-in jsonb. It is the same as its jsonb_ namesake.';

CREATE OR REPLACE FUNCTION _ps_trace.tag_v_send(_ps_trace.tag_v)
RETURNS bytea
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$jsonb_send$function$
;
COMMENT ON FUNCTION _ps_trace.tag_v_send
IS 'This function is a part of custom _ps_trace.tag_v type which is a wrapper for the built-in jsonb. It is the same as its jsonb_ namesake.';

CREATE OR REPLACE FUNCTION _ps_trace.tag_v_recv(internal)
RETURNS _ps_trace.tag_v
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$jsonb_recv$function$
;
COMMENT ON FUNCTION _ps_trace.tag_v_recv
IS 'This function is a part of custom _ps_trace.tag_v type which is a wrapper for the built-in jsonb. It is the same as its jsonb_ namesake.';

DO
$do$

/* Create subscript_handler function for pg v14+.
 * For pg v13 jsonb type doesn't have a subscript_handler function so it shall
 * be omitted.
 */
DECLARE
    _pg_version int4 := pg_catalog.current_setting('server_version_num')::int4;
BEGIN
    IF (_pg_version >= 140000) THEN
        CREATE OR REPLACE FUNCTION _ps_trace.tag_v_subscript_handler(internal)
                RETURNS internal
                LANGUAGE internal
                IMMUTABLE PARALLEL SAFE STRICT
                AS $f$jsonb_subscript_handler$f$;
        COMMENT ON FUNCTION _ps_trace.tag_v_subscript_handler
        IS 'This function is a part of custom _ps_trace.tag_v type which is a wrapper for the built-in jsonb. It is the same as its jsonb_ namesake.';
        /* Add subscript handler in case of a prior PG13 -> PG14 upgrade that
         * didn't take care of this
         */
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_type
            WHERE typname      = 'tag_v'
              AND typnamespace = '_ps_trace'::regnamespace
              AND typsubscript = '_ps_trace.tag_v_subscript_handler'::regproc
            ) THEN
                ALTER TYPE _ps_trace.tag_v SET (SUBSCRIPT = _ps_trace.tag_v_subscript_handler);
        END IF;
    END IF;
END
$do$;

