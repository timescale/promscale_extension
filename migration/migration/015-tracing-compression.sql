-- Due to incompatible change of trace_id type we need to drop tables and delete data
DROP TABLE _ps_trace.link CASCADE;
DROP TABLE _ps_trace.event CASCADE;
DROP TABLE _ps_trace.span CASCADE;
/* XXX We drop these views because they depend on some changes ahead
 * Although they should be dropped by now due to commands above, it's
 * better to be explicit here.
 */
DROP VIEW IF EXISTS ps_trace.event CASCADE;
DROP VIEW IF EXISTS ps_trace.link CASCADE;
DROP VIEW IF EXISTS ps_trace.span CASCADE;

TRUNCATE TABLE _ps_trace.tag;
DELETE FROM _ps_trace.tag_key WHERE id >= 1000;
ANALYZE _ps_trace.tag_key;
REINDEX TABLE _ps_trace.tag_key;
PERFORM setval('_ps_trace.tag_key_id_seq', 1000);
TRUNCATE TABLE _ps_trace.operation;
ANALYZE _ps_trace.operation;
TRUNCATE TABLE _ps_trace.instrumentation_lib CASCADE;
ANALYZE _ps_trace.instrumentation_lib;
TRUNCATE TABLE _ps_trace.schema_url CASCADE;
ANALYZE _ps_trace.schema_url;

ALTER TABLE _ps_trace.tag DROP CONSTRAINT tag_key_value_id_key_id_key;
CREATE UNIQUE INDEX tag_key_value_id_key_id_key ON _ps_trace.tag (key, _prom_ext.jsonb_digest(value)) INCLUDE (id, key_id);

-- We are replacing domain with custom type
DROP DOMAIN ps_trace.trace_id CASCADE;

CREATE TYPE ps_trace.trace_id;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_in(cstring)
RETURNS ps_trace.trace_id
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_in$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_in(cstring) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_out(ps_trace.trace_id)
RETURNS cstring
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_out$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_out(ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_send(ps_trace.trace_id)
RETURNS bytea
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_send$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_send(ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_recv(internal)
RETURNS ps_trace.trace_id
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_recv$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_recv(internal) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_ne(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_ne$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_ne(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_eq(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_eq$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_eq(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_ge(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_ge$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_ge(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_le(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_le$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_le(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_gt(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_gt$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_gt(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_lt(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_lt$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_lt(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_cmp(ps_trace.trace_id, ps_trace.trace_id)
RETURNS int
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_cmp$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_cmp(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_hash(ps_trace.trace_id)
RETURNS int
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_hash$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_hash(ps_trace.trace_id) TO prom_reader;

CREATE TYPE ps_trace.trace_id(
    internallength = 16,
    INPUT = _ps_trace.trace_id_in,
    OUTPUT = _ps_trace.trace_id_out,
    SEND = _ps_trace.trace_id_send,
    RECEIVE = _ps_trace.trace_id_recv,
    alignment = char
);

CREATE OPERATOR ps_trace.= (
    FUNCTION=_ps_trace.trace_id_eq,
    LEFTARG=ps_trace.trace_id,
    RIGHTARG=ps_trace.trace_id,
    COMMUTATOR= OPERATOR(ps_trace.=),
    NEGATOR= OPERATOR(ps_trace.!=),
    RESTRICT=eqsel,
    JOIN=eqjoinsel,
    HASHES, MERGES);

CREATE OPERATOR ps_trace.<> (
    FUNCTION=_ps_trace.trace_id_ne,
    LEFTARG=ps_trace.trace_id,
    RIGHTARG=ps_trace.trace_id,
    COMMUTATOR= OPERATOR(ps_trace.<>),
    NEGATOR= OPERATOR(ps_trace.=),
    RESTRICT=neqsel,
    JOIN=neqjoinsel);

CREATE OPERATOR ps_trace.> (
    FUNCTION=_ps_trace.trace_id_gt,
    LEFTARG=ps_trace.trace_id,
    RIGHTARG=ps_trace.trace_id,
    COMMUTATOR= OPERATOR(ps_trace.<),
    NEGATOR= OPERATOR(ps_trace.<=),
    RESTRICT=scalargtsel,
    JOIN=scalargtjoinsel);

CREATE OPERATOR ps_trace.>= (
    FUNCTION=_ps_trace.trace_id_ge,
    LEFTARG=ps_trace.trace_id,
    RIGHTARG=ps_trace.trace_id,
    COMMUTATOR= OPERATOR(ps_trace.<=),
    NEGATOR= OPERATOR(ps_trace.<),
    RESTRICT=scalargesel,
    JOIN=scalargejoinsel);

CREATE OPERATOR ps_trace.< (
    FUNCTION=_ps_trace.trace_id_lt,
    LEFTARG=ps_trace.trace_id,
    RIGHTARG=ps_trace.trace_id,
    COMMUTATOR= OPERATOR(ps_trace.>),
    NEGATOR= OPERATOR(ps_trace.>=),
    RESTRICT=scalarltsel,
    JOIN=scalarltjoinsel);

CREATE OPERATOR ps_trace.<= (
    FUNCTION=_ps_trace.trace_id_le,
    LEFTARG=ps_trace.trace_id,
    RIGHTARG=ps_trace.trace_id,
    COMMUTATOR= OPERATOR(ps_trace.>=),
    NEGATOR= OPERATOR(ps_trace.>),
    RESTRICT=scalarlesel,
    JOIN=scalarlejoinsel);

CREATE OPERATOR CLASS ps_trace.btree_trace_id_ops
DEFAULT FOR TYPE ps_trace.trace_id USING btree AS
    OPERATOR        1       ps_trace.< ,
    OPERATOR        2       ps_trace.<= ,
    OPERATOR        3       ps_trace.= ,
    OPERATOR        4       ps_trace.>= ,
    OPERATOR        5       ps_trace.> ,
    FUNCTION 1 _ps_trace.trace_id_cmp(ps_trace.trace_id,ps_trace.trace_id);

CREATE OPERATOR CLASS ps_trace.hash_trace_id_ops
DEFAULT FOR TYPE ps_trace.trace_id USING hash AS
    OPERATOR 1 ps_trace.=,
    FUNCTION 1 _ps_trace.trace_id_hash(ps_trace.trace_id);

GRANT USAGE ON TYPE ps_trace.trace_id TO prom_reader;

/* Move the old tag_map type out of the way */
ALTER DOMAIN ps_trace.tag_map
    RENAME TO tag_map_old;
ALTER DOMAIN ps_trace.tag_map_old
    SET SCHEMA _ps_trace;

/* Define custom tag_map and tag_v json aliases
    * NOTE: We need to keep an eye on upstream jsonb type
    * and keep these up-to-date.
    */

    CREATE TYPE ps_trace.tag_map;
    CREATE TYPE _ps_trace.tag_v;

    CREATE OR REPLACE FUNCTION ps_trace.tag_map_in(cstring)
    RETURNS ps_trace.tag_map
    LANGUAGE internal
    IMMUTABLE PARALLEL SAFE STRICT
    AS $function$jsonb_in$function$
    ;

    CREATE OR REPLACE FUNCTION ps_trace.tag_map_out(ps_trace.tag_map)
    RETURNS cstring
    LANGUAGE internal
    IMMUTABLE PARALLEL SAFE STRICT
    AS $function$jsonb_out$function$
    ;

    CREATE OR REPLACE FUNCTION ps_trace.tag_map_send(ps_trace.tag_map)
    RETURNS bytea
    LANGUAGE internal
    IMMUTABLE PARALLEL SAFE STRICT
    AS $function$jsonb_send$function$
    ;

    CREATE OR REPLACE FUNCTION ps_trace.tag_map_recv(internal)
    RETURNS ps_trace.tag_map
    LANGUAGE internal
    IMMUTABLE PARALLEL SAFE STRICT
    AS $function$jsonb_recv$function$
    ;

    DO
    $do$
    /* Create subscript_handler function for pg v14+ and the type accordingly.
    * For pg v13 jsonb type doesn't have a subscript_handler function so it shall
    * be omitted.
    */
    DECLARE
        _pg_version int4 := current_setting('server_version_num')::int4;
    BEGIN
        IF (_pg_version >= 140000) THEN
            EXECUTE
                'CREATE OR REPLACE FUNCTION ps_trace.tag_map_subscript_handler(internal) ' ||
                    'RETURNS internal '                 ||
                    'LANGUAGE internal '                ||
                    'IMMUTABLE PARALLEL SAFE STRICT '   ||
                    'AS $f$jsonb_subscript_handler$f$;'
                ;

            EXECUTE
                'CREATE TYPE ps_trace.tag_map ( '       ||
                    'INPUT = ps_trace.tag_map_in, '     ||
                    'OUTPUT = ps_trace.tag_map_out, '   ||
                    'SEND = ps_trace.tag_map_send, '    ||
                    'RECEIVE = ps_trace.tag_map_recv, ' ||
                    'SUBSCRIPT = ps_trace.tag_map_subscript_handler);'
                ;

        ELSE
            EXECUTE
                'CREATE TYPE ps_trace.tag_map ( '       ||
                    'INPUT = ps_trace.tag_map_in, '     ||
                    'OUTPUT = ps_trace.tag_map_out, '   ||
                    'SEND = ps_trace.tag_map_send, '    ||
                    'RECEIVE = ps_trace.tag_map_recv);'
                ;

        END IF;
    END
    $do$;


    CREATE CAST (jsonb AS ps_trace.tag_map) WITHOUT FUNCTION AS IMPLICIT;
    CREATE CAST (ps_trace.tag_map AS jsonb) WITHOUT FUNCTION AS IMPLICIT;

    CREATE CAST (json AS ps_trace.tag_map) WITH INOUT AS ASSIGNMENT;
    CREATE CAST (ps_trace.tag_map AS json) WITH INOUT AS ASSIGNMENT;

    -- CREATE CAST (text AS ps_trace.tag_map) WITH INOUT AS IMPLICIT;
    -- CREATE CAST (ps_trace.tag_map AS text) WITH INOUT AS ASSIGNMENT;


    CREATE OR REPLACE FUNCTION _ps_trace.tag_v_in(cstring)
    RETURNS _ps_trace.tag_v
    LANGUAGE internal
    IMMUTABLE PARALLEL SAFE STRICT
    AS $function$jsonb_in$function$
    ;

    CREATE OR REPLACE FUNCTION _ps_trace.tag_v_out(_ps_trace.tag_v)
    RETURNS cstring
    LANGUAGE internal
    IMMUTABLE PARALLEL SAFE STRICT
    AS $function$jsonb_out$function$
    ;

    CREATE OR REPLACE FUNCTION _ps_trace.tag_v_send(_ps_trace.tag_v)
    RETURNS bytea
    LANGUAGE internal
    IMMUTABLE PARALLEL SAFE STRICT
    AS $function$jsonb_send$function$
    ;

    CREATE OR REPLACE FUNCTION _ps_trace.tag_v_recv(internal)
    RETURNS _ps_trace.tag_v
    LANGUAGE internal
    IMMUTABLE PARALLEL SAFE STRICT
    AS $function$jsonb_recv$function$
    ;

    DO
    $do$
    /* Create subscript_handler function for pg v14+ and the type accordingly.
    * For pg v13 jsonb type doesn't have a subscript_handler function so it shall
    * be omitted.
    */
    DECLARE
        _pg_version int4 := pg_catalog.current_setting('server_version_num')::int4;
    BEGIN
        IF (_pg_version >= 140000) THEN
            EXECUTE
                'CREATE OR REPLACE FUNCTION _ps_trace.tag_v_subscript_handler(internal) ' ||
                    'RETURNS internal '                 ||
                    'LANGUAGE internal '                ||
                    'IMMUTABLE PARALLEL SAFE STRICT '   ||
                    'AS $f$jsonb_subscript_handler$f$;'
                ;

            EXECUTE
                'CREATE TYPE _ps_trace.tag_v ( '       ||
                    'INPUT = _ps_trace.tag_v_in, '     ||
                    'OUTPUT = _ps_trace.tag_v_out, '   ||
                    'SEND = _ps_trace.tag_v_send, '    ||
                    'RECEIVE = _ps_trace.tag_v_recv, ' ||
                    'SUBSCRIPT = _ps_trace.tag_v_subscript_handler);'
                ;

        ELSE
            EXECUTE
                'CREATE TYPE _ps_trace.tag_v ( '       ||
                    'INPUT = _ps_trace.tag_v_in, '     ||
                    'OUTPUT = _ps_trace.tag_v_out, '   ||
                    'SEND = _ps_trace.tag_v_send, '    ||
                    'RECEIVE = _ps_trace.tag_v_recv);'
                ;

        END IF;
    END
    $do$;

    GRANT USAGE ON TYPE ps_trace.tag_map TO prom_reader;
    GRANT USAGE ON TYPE ps_trace.tag_v TO prom_reader;

    /* XXX
    * _ps_trace.span table is now used indirectly, thus its name has changed
    */

    CREATE TABLE _ps_trace._span
    (
        trace_id ps_trace.trace_id NOT NULL,
        span_id bigint NOT NULL, /* not allowed to be 0 */
        parent_span_id bigint NULL, /* if set not allowed be 0 */
        operation_id bigint NOT NULL,
        start_time timestamptz NOT NULL,
        end_time timestamptz NOT NULL,
        duration_ms double precision NOT NULL,
        instrumentation_lib_id bigint,
        resource_schema_url_id bigint,
        event_time tstzrange default NULL,
        dropped_tags_count int NOT NULL default 0,
        dropped_events_count int NOT NULL default 0,
        dropped_link_count int NOT NULL default 0,
        resource_dropped_tags_count int NOT NULL default 0,
        status_code ps_trace.status_code NOT NULL,
        trace_state text, /* empty string not allowed */
        span_tags ps_trace.tag_map NOT NULL,
        status_message text,
        resource_tags ps_trace.tag_map NOT NULL,
        PRIMARY KEY (span_id, trace_id, start_time)
    );

    /* Define a view that would provide the same interface
    * as _ps_trace.span used to have.
    * Also define everything else we need for the view to function properly.
    */


    /* NOTE: This function cannot be inlined since it's used in a scalar
    * context and uses an aggregate
    */
    CREATE FUNCTION ps_trace.tag_map_denormalize(_map ps_trace.tag_map)
        RETURNS ps_trace.tag_map
        LANGUAGE sql STABLE
        PARALLEL SAFE AS
    $fnc$
        SELECT ps_trace.jsonb_cat(pg_catalog.jsonb_build_object(t.key, t.value))
            FROM pg_catalog.jsonb_each(_map) f(k,v)
                JOIN _ps_trace.tag t ON
                        f.k::int8 = t.key_id
                    AND f.v::int8 = t.id;
    $fnc$;


    CREATE VIEW _ps_trace.span AS
    SELECT
            trace_id,
            span_id,
            parent_span_id,
            operation_id,
            start_time,
            end_time,
            duration_ms,
            instrumentation_lib_id,
            resource_schema_url_id,
            event_time,
            dropped_tags_count,
            dropped_events_count,
            dropped_link_count,
            resource_dropped_tags_count,
            status_code,
            trace_state,
            ps_trace.tag_map_denormalize(span_tags) AS span_tags,
            status_message,
            ps_trace.tag_map_denormalize(resource_tags) AS resource_tags
        FROM _ps_trace._span
    ;
    GRANT SELECT ON _ps_trace.span TO prom_reader;

CREATE INDEX ON _ps_trace._span USING BTREE (trace_id, parent_span_id) INCLUDE (span_id); -- used for recursive CTEs for trace tree queries
CREATE INDEX ON _ps_trace._span USING GIN (span_tags jsonb_path_ops); -- supports tag filters. faster ingest than json_ops
CREATE INDEX ON _ps_trace._span USING BTREE (operation_id); -- supports filters/joins to operation table
--CREATE INDEX ON _ps_trace._span USING GIN (jsonb_object_keys(span_tags) array_ops); -- possible way to index key exists
CREATE INDEX ON _ps_trace._span USING GIN (resource_tags jsonb_path_ops); -- supports tag filters. faster ingest than json_ops
GRANT SELECT ON TABLE _ps_trace._span TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace._span TO prom_writer;

CREATE TABLE _ps_trace.event
(
    time timestamptz NOT NULL,
    trace_id ps_trace.trace_id NOT NULL,
    span_id bigint NOT NULL, /* not allowed to be 0 */
    event_nbr int NOT NULL DEFAULT 0,
    dropped_tags_count int NOT NULL DEFAULT 0,
    name text NOT NULL,
    tags ps_trace.tag_map NOT NULL
);
CREATE INDEX ON _ps_trace.event USING GIN (tags jsonb_path_ops);
CREATE INDEX ON _ps_trace.event USING BTREE (trace_id, span_id);
GRANT SELECT ON TABLE _ps_trace.event TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.event TO prom_writer;

CREATE TABLE _ps_trace.link
(
    trace_id ps_trace.trace_id NOT NULL,
    span_id bigint NOT NULL,
    span_start_time timestamptz NOT NULL,
    linked_trace_id ps_trace.trace_id NOT NULL,
    linked_span_id bigint NOT NULL, /* not allowed to be 0 */
    link_nbr int NOT NULL DEFAULT 0,
    dropped_tags_count int NOT NULL DEFAULT 0,
    trace_state text, /* empty string not allowed */
    tags ps_trace.tag_map NOT NULL
);
CREATE INDEX ON _ps_trace.link USING BTREE (trace_id, span_id);
CREATE INDEX ON _ps_trace.link USING GIN (tags jsonb_path_ops);
GRANT SELECT ON TABLE _ps_trace.link TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.link TO prom_writer;

/* Recreate previously dropped ps_trace.span view*/

CREATE OR REPLACE VIEW ps_trace.span AS
SELECT
    s.trace_id,
    s.span_id,
    s.trace_state,
    s.parent_span_id,
    s.parent_span_id is null as is_root_span,
    t.value #>> '{}' as service_name,
    o.span_name,
    o.span_kind,
    s.start_time,
    s.end_time,
    tstzrange(s.start_time, s.end_time, '[]') as time_range,
    s.duration_ms,
    s.span_tags,
    s.dropped_tags_count,
    s.event_time,
    s.dropped_events_count,
    s.dropped_link_count,
    s.status_code,
    s.status_message,
    il.name as instrumentation_lib_name,
    il.version as instrumentation_lib_version,
    u1.url as instrumentation_lib_schema_url,
    s.resource_tags,
    s.resource_dropped_tags_count,
    u2.url as resource_schema_url
FROM _ps_trace.span s
LEFT OUTER JOIN _ps_trace.operation o ON (s.operation_id = o.id)
LEFT OUTER JOIN _ps_trace.tag t ON (o.service_name_id = t.id AND t.key = 'service.name') -- partition elimination
LEFT OUTER JOIN _ps_trace.instrumentation_lib il ON (s.instrumentation_lib_id = il.id)
LEFT OUTER JOIN _ps_trace.schema_url u1 on (il.schema_url_id = u1.id)
LEFT OUTER JOIN _ps_trace.schema_url u2 on (il.schema_url_id = u2.id)
;
GRANT SELECT ON ps_trace.span to prom_reader;

CREATE OR REPLACE VIEW ps_trace.event AS
SELECT
    e.trace_id,
    e.span_id,
    e.time,
    e.name as event_name,
    e.tags as event_tags,
    e.dropped_tags_count,
    s.trace_state,
    t.value #>> '{}' as service_name,
    o.span_name,
    o.span_kind,
    s.start_time as span_start_time,
    s.end_time as span_end_time,
    tstzrange(s.start_time, s.end_time, '[]') as span_time_range,
    s.duration_ms as span_duration_ms,
    s.span_tags,
    s.dropped_tags_count as dropped_span_tags_count,
    s.resource_tags,
    s.resource_dropped_tags_count,
    s.status_code,
    s.status_message
FROM _ps_trace.event e
LEFT OUTER JOIN _ps_trace.span s on (e.span_id = s.span_id AND e.trace_id OPERATOR(ps_trace.=) s.trace_id)
LEFT OUTER JOIN _ps_trace.operation o ON (s.operation_id = o.id)
LEFT OUTER JOIN _ps_trace.tag t ON (o.service_name_id = t.id AND t.key = 'service.name') -- partition elimination
;
GRANT SELECT ON ps_trace.event to prom_reader;

CREATE OR REPLACE VIEW ps_trace.link AS
SELECT
    s1.trace_id                         ,
    s1.span_id                          ,
    s1.trace_state                      ,
    s1.parent_span_id                   ,
    s1.is_root_span                     ,
    s1.service_name                     ,
    s1.span_name                        ,
    s1.span_kind                        ,
    s1.start_time                       ,
    s1.end_time                         ,
    s1.time_range                       ,
    s1.duration_ms                      ,
    s1.span_tags                        ,
    s1.dropped_tags_count               ,
    s1.event_time                       ,
    s1.dropped_events_count             ,
    s1.dropped_link_count               ,
    s1.status_code                      ,
    s1.status_message                   ,
    s1.instrumentation_lib_name         ,
    s1.instrumentation_lib_version      ,
    s1.instrumentation_lib_schema_url   ,
    s1.resource_tags                    ,
    s1.resource_dropped_tags_count      ,
    s1.resource_schema_url              ,
    s2.trace_id                         as linked_trace_id                   ,
    s2.span_id                          as linked_span_id                    ,
    s2.trace_state                      as linked_trace_state                ,
    s2.parent_span_id                   as linked_parent_span_id             ,
    s2.is_root_span                     as linked_is_root_span               ,
    s2.service_name                     as linked_service_name               ,
    s2.span_name                        as linked_span_name                  ,
    s2.span_kind                        as linked_span_kind                  ,
    s2.start_time                       as linked_start_time                 ,
    s2.end_time                         as linked_end_time                   ,
    s2.time_range                       as linked_time_range                 ,
    s2.duration_ms                      as linked_duration_ms                ,
    s2.span_tags                        as linked_span_tags                  ,
    s2.dropped_tags_count               as linked_dropped_tags_count         ,
    s2.event_time                       as linked_event_time                 ,
    s2.dropped_events_count             as linked_dropped_events_count       ,
    s2.dropped_link_count               as linked_dropped_link_count         ,
    s2.status_code                      as linked_status_code                ,
    s2.status_message                   as linked_status_message             ,
    s2.instrumentation_lib_name         as linked_inst_lib_name              ,
    s2.instrumentation_lib_version      as linked_inst_lib_version           ,
    s2.instrumentation_lib_schema_url   as linked_inst_lib_schema_url        ,
    s2.resource_tags                    as linked_resource_tags              ,
    s2.resource_dropped_tags_count      as linked_resource_dropped_tags_count,
    s2.resource_schema_url              as linked_resource_schema_url        ,
    k.tags as link_tags,
    k.dropped_tags_count as dropped_link_tags_count
FROM _ps_trace.link k
LEFT OUTER JOIN ps_trace.span s1 on (k.span_id = s1.span_id and k.trace_id OPERATOR(ps_trace.=) s1.trace_id)
LEFT OUTER JOIN ps_trace.span s2 on (k.linked_span_id = s2.span_id and k.linked_trace_id OPERATOR(ps_trace.=) s2.trace_id)
;
GRANT SELECT ON ps_trace.link to prom_reader;


/*
    If "vanilla" postgres is installed, do nothing.
    If timescaledb is installed, turn on compression for tracing tables.
    If timescaledb is installed and multinode is set up,
    turn span, event, and link into distributed hypertables.
    If timescaledb is installed but multinode is NOT set up,
    turn span, event, and link into regular hypertables.
*/
DO $block$
DECLARE
    _is_timescaledb_installed boolean = false;
    _is_compression_available boolean = false;
    _is_multinode boolean = false;
    _saved_search_path text;
BEGIN
    _is_timescaledb_installed = _prom_catalog.is_timescaledb_installed();


    IF _is_timescaledb_installed THEN
        _is_compression_available = NOT (current_setting('timescaledb.license') = 'apache');
        _is_multinode = _prom_catalog.is_multinode();
    END IF;

    IF _is_timescaledb_installed THEN
        IF _is_multinode THEN
            PERFORM public.create_distributed_hypertable(
                '_ps_trace._span'::regclass,
                'start_time'::name,
                partitioning_column=>'trace_id'::name,
                number_partitions=>1::int,
                chunk_time_interval=>'1 hours'::interval,
                create_default_indexes=>false
            );
            PERFORM public.create_distributed_hypertable(
                '_ps_trace.event'::regclass,
                'time'::name,
                partitioning_column=>'trace_id'::name,
                number_partitions=>1::int,
                chunk_time_interval=>'1 hours'::interval,
                create_default_indexes=>false
            );
            PERFORM public.create_distributed_hypertable(
                '_ps_trace.link'::regclass,
                'span_start_time'::name,
                partitioning_column=>'trace_id'::name,
                number_partitions=>1::int,
                chunk_time_interval=>'1 hours'::interval,
                create_default_indexes=>false
            );
        ELSE -- not multinode
            PERFORM public.create_hypertable(
                '_ps_trace._span'::regclass,
                'start_time'::name,
                partitioning_column=>'trace_id'::name,
                number_partitions=>1::int,
                chunk_time_interval=>'1 hours'::interval,
                create_default_indexes=>false
            );
            PERFORM public.create_hypertable(
                '_ps_trace.event'::regclass,
                'time'::name,
                partitioning_column=>'trace_id'::name,
                number_partitions=>1::int,
                chunk_time_interval=>'1 hours'::interval,
                create_default_indexes=>false
            );
            PERFORM public.create_hypertable(
                '_ps_trace.link'::regclass,
                'span_start_time'::name,
                partitioning_column=>'trace_id'::name,
                number_partitions=>1::int,
                chunk_time_interval=>'1 hours'::interval,
                create_default_indexes=>false
            );
        END IF;

        IF _is_compression_available THEN
            -- turn on compression
            ALTER TABLE _ps_trace._span SET (timescaledb.compress, timescaledb.compress_orderby='trace_id,span_id,start_time');
            ALTER TABLE _ps_trace.event SET (timescaledb.compress, timescaledb.compress_orderby='trace_id,span_id,time');
            ALTER TABLE _ps_trace.link SET (timescaledb.compress, timescaledb.compress_orderby='trace_id,span_id,span_start_time');

            PERFORM public.add_compression_policy('_ps_trace._span', INTERVAL '1 hours');
            PERFORM public.add_compression_policy('_ps_trace.event', INTERVAL '1 hours');
            PERFORM public.add_compression_policy('_ps_trace.link', INTERVAL '1 hours');
        END IF;
    END IF;
END;
$block$
;
