CALL _prom_catalog.execute_everywhere('tracing_types', $ee$ DO $$ BEGIN

    CREATE DOMAIN ps_trace.trace_id uuid NOT NULL CHECK (value != '00000000-0000-0000-0000-000000000000');
    GRANT USAGE ON DOMAIN ps_trace.trace_id TO prom_reader;

    CREATE DOMAIN ps_trace.tag_k text NOT NULL CHECK (value != '');
    GRANT USAGE ON DOMAIN ps_trace.tag_k TO prom_reader;

    CREATE DOMAIN ps_trace.tag_v jsonb NOT NULL;
    GRANT USAGE ON DOMAIN ps_trace.tag_v TO prom_reader;

    CREATE DOMAIN ps_trace.tag_map_old jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(value) = 'object');
    GRANT USAGE ON DOMAIN ps_trace.tag_map TO prom_reader;

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

    /* Define a view that would provide the same interface
    * as _ps_trace.span used to have.
    * Also define everything else we need for the view to function properly.
    */

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


    CREATE DOMAIN ps_trace.tag_type smallint NOT NULL; --bitmap, may contain several types
    GRANT USAGE ON DOMAIN ps_trace.tag_type TO prom_reader;

    CREATE TYPE ps_trace.span_kind AS ENUM
    (
        'SPAN_KIND_UNSPECIFIED',
        'SPAN_KIND_INTERNAL',
        'SPAN_KIND_SERVER',
        'SPAN_KIND_CLIENT',
        'SPAN_KIND_PRODUCER',
        'SPAN_KIND_CONSUMER'
    );
    GRANT USAGE ON TYPE ps_trace.span_kind TO prom_reader;

    CREATE TYPE ps_trace.status_code AS ENUM
    (
        'STATUS_CODE_UNSET',
        'STATUS_CODE_OK',
        'STATUS_CODE_ERROR'
    );
    GRANT USAGE ON TYPE ps_trace.status_code TO prom_reader;
END $$ $ee$);

INSERT INTO public.prom_installation_info(key, value) VALUES
    ('tagging schema',          'ps_tag'),
    ('tracing schema',          'ps_trace'),
    ('tracing schema private',  '_ps_trace')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE _ps_trace.tag_key
(
    id BIGINT NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tag_type ps_trace.tag_type NOT NULL,
    key ps_trace.tag_k NOT NULL
);
CREATE UNIQUE INDEX ON _ps_trace.tag_key (key) INCLUDE (id, tag_type);
GRANT SELECT ON TABLE _ps_trace.tag_key TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.tag_key TO prom_writer;
GRANT USAGE ON SEQUENCE _ps_trace.tag_key_id_seq TO prom_writer;

CREATE TABLE _ps_trace.tag
(
    id BIGINT NOT NULL GENERATED ALWAYS AS IDENTITY,
    tag_type ps_trace.tag_type NOT NULL,
    key_id bigint NOT NULL,
    key ps_trace.tag_k NOT NULL REFERENCES _ps_trace.tag_key (key) ON DELETE CASCADE,
    value ps_trace.tag_v NOT NULL,
    UNIQUE (key, value) INCLUDE (id, key_id)
)
PARTITION BY HASH (key);
GRANT SELECT ON TABLE _ps_trace.tag TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.tag TO prom_writer;
GRANT USAGE ON SEQUENCE _ps_trace.tag_id_seq TO prom_writer;

-- create the partitions of the tag table
DO $block$
DECLARE
    _i bigint;
    _max bigint = 64;
BEGIN
    FOR _i IN 1.._max
    LOOP
        EXECUTE format($sql$
            CREATE TABLE _ps_trace.tag_%s PARTITION OF _ps_trace.tag FOR VALUES WITH (MODULUS %s, REMAINDER %s)
            $sql$, _i, _max, _i - 1);
        EXECUTE format($sql$
            ALTER TABLE _ps_trace.tag_%s ADD PRIMARY KEY (id)
            $sql$, _i);
        EXECUTE format($sql$
            GRANT SELECT ON TABLE _ps_trace.tag_%s TO prom_reader
            $sql$, _i);
        EXECUTE format($sql$
            GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.tag_%s TO prom_writer
            $sql$, _i);
    END LOOP;
END
$block$
;

CREATE TABLE IF NOT EXISTS _ps_trace.operation
(
    id bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    service_name_id bigint not null, -- references id column of tag table for the service.name tag value
    span_kind ps_trace.span_kind not null,
    span_name text NOT NULL CHECK (span_name != ''),
    UNIQUE (service_name_id, span_name, span_kind)
);
GRANT SELECT ON TABLE _ps_trace.operation TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.operation TO prom_writer;
GRANT USAGE ON SEQUENCE _ps_trace.operation_id_seq TO prom_writer;

CREATE TABLE IF NOT EXISTS _ps_trace.schema_url
(
    id bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    url text NOT NULL CHECK (url != '') UNIQUE
);
GRANT SELECT ON TABLE _ps_trace.schema_url TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.schema_url TO prom_writer;
GRANT USAGE ON SEQUENCE _ps_trace.schema_url_id_seq TO prom_writer;

CREATE TABLE IF NOT EXISTS _ps_trace.instrumentation_lib
(
    id bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL,
    version text NOT NULL,
    schema_url_id BIGINT REFERENCES _ps_trace.schema_url(id),
    UNIQUE(name, version, schema_url_id)
);
GRANT SELECT ON TABLE _ps_trace.instrumentation_lib TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.instrumentation_lib TO prom_writer;
GRANT USAGE ON SEQUENCE _ps_trace.instrumentation_lib_id_seq TO prom_writer;

CREATE TABLE IF NOT EXISTS _ps_trace.span
(
    trace_id ps_trace.trace_id NOT NULL,
    span_id bigint NOT NULL CHECK (span_id != 0),
    parent_span_id bigint NULL CHECK (parent_span_id != 0),
    operation_id bigint NOT NULL,
    start_time timestamptz NOT NULL,
    end_time timestamptz NOT NULL,
    duration_ms double precision NOT NULL GENERATED ALWAYS AS ( extract(epoch from (end_time - start_time)) * 1000.0 ) STORED,
    trace_state text CHECK (trace_state != ''),
    span_tags ps_trace.tag_map NOT NULL,
    dropped_tags_count int NOT NULL default 0,
    event_time tstzrange default NULL,
    dropped_events_count int NOT NULL default 0,
    dropped_link_count int NOT NULL default 0,
    status_code ps_trace.status_code NOT NULL,
    status_message text,
    instrumentation_lib_id bigint,
    resource_tags ps_trace.tag_map NOT NULL,
    resource_dropped_tags_count int NOT NULL default 0,
    resource_schema_url_id BIGINT,
    PRIMARY KEY (span_id, trace_id, start_time),
    CHECK (start_time <= end_time)
);
CREATE INDEX ON _ps_trace.span USING BTREE (trace_id, parent_span_id) INCLUDE (span_id); -- used for recursive CTEs for trace tree queries
CREATE INDEX ON _ps_trace.span USING GIN (span_tags jsonb_path_ops); -- supports tag filters. faster ingest than json_ops
CREATE INDEX ON _ps_trace.span USING BTREE (operation_id); -- supports filters/joins to operation table
--CREATE INDEX ON _ps_trace.span USING GIN (jsonb_object_keys(span_tags) array_ops); -- possible way to index key exists
CREATE INDEX ON _ps_trace.span USING GIN (resource_tags jsonb_path_ops); -- supports tag filters. faster ingest than json_ops
GRANT SELECT ON TABLE _ps_trace.span TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.span TO prom_writer;

CREATE TABLE IF NOT EXISTS _ps_trace.event
(
    time timestamptz NOT NULL,
    trace_id ps_trace.trace_id NOT NULL,
    span_id bigint NOT NULL CHECK (span_id != 0),
    event_nbr int NOT NULL DEFAULT 0,
    name text NOT NULL,
    tags ps_trace.tag_map NOT NULL,
    dropped_tags_count int NOT NULL DEFAULT 0
);
CREATE INDEX ON _ps_trace.event USING GIN (tags jsonb_path_ops);
CREATE INDEX ON _ps_trace.event USING BTREE (trace_id, span_id);
GRANT SELECT ON TABLE _ps_trace.event TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.event TO prom_writer;

CREATE TABLE IF NOT EXISTS _ps_trace.link
(
    trace_id ps_trace.trace_id NOT NULL,
    span_id bigint NOT NULL CHECK (span_id != 0),
    span_start_time timestamptz NOT NULL,
    linked_trace_id ps_trace.trace_id NOT NULL,
    linked_span_id bigint NOT NULL CHECK (linked_span_id != 0),
    link_nbr int NOT NULL DEFAULT 0,
    trace_state text CHECK (trace_state != ''),
    tags ps_trace.tag_map NOT NULL,
    dropped_tags_count int NOT NULL DEFAULT 0
);
CREATE INDEX ON _ps_trace.link USING BTREE (trace_id, span_id);
CREATE INDEX ON _ps_trace.link USING GIN (tags jsonb_path_ops);
GRANT SELECT ON TABLE _ps_trace.link TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_trace.link TO prom_writer;

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
    _is_timescaledb_oss boolean = true;
    _timescaledb_version_text text;
    _timescaledb_major_version int;
    _timescaledb_minor_version int;
    _is_compression_available boolean = false;
    _is_multinode boolean = false;
    _is_restore_in_progress boolean = false;
BEGIN
    /*
        These functions do not exist until the
        idempotent scripts are executed, so we have
        to deal with it "manually"
        _prom_catalog.get_timescale_major_version()
        _prom_catalog.is_timescaledb_oss()
        _prom_catalog.is_timescaledb_installed()
        _prom_catalog.is_multinode()
        _prom_catalog.get_default_chunk_interval()
        _prom_catalog.get_staggered_chunk_interval(...)
    */
    SELECT count(*) > 0
    INTO STRICT _is_timescaledb_installed
    FROM pg_extension
    WHERE extname='timescaledb';

    IF _is_timescaledb_installed THEN
        SELECT extversion INTO STRICT _timescaledb_version_text
        FROM pg_catalog.pg_extension
        WHERE extname='timescaledb'
        LIMIT 1;

        _timescaledb_major_version = split_part(_timescaledb_version_text, '.', 1)::INT;
        _timescaledb_minor_version = split_part(_timescaledb_version_text, '.', 2)::INT;

        _is_compression_available = CASE
            WHEN _timescaledb_major_version >= 2 THEN true
            WHEN _timescaledb_major_version = 1 and _timescaledb_minor_version >= 5 THEN true
            ELSE false
        END;

        IF _timescaledb_major_version >= 2 THEN
            _is_timescaledb_oss = (current_setting('timescaledb.license') = 'apache');
        ELSE
            _is_timescaledb_oss = (SELECT edition = 'apache' FROM timescaledb_information.license);
        END IF;

        IF _timescaledb_major_version >= 2 THEN
            SELECT count(*) > 0
            INTO STRICT _is_multinode
            FROM timescaledb_information.data_nodes;
        END IF;

        _is_restore_in_progress = coalesce(
            (SELECT setting::boolean from pg_catalog.pg_settings where name = 'timescaledb.restoring'), false
            );
    END IF;

    IF _is_timescaledb_installed AND NOT _is_restore_in_progress THEN
        IF _is_multinode THEN
            PERFORM public.create_distributed_hypertable(
                '_ps_trace.span'::regclass,
                'start_time'::name,
                partitioning_column=>'trace_id'::name,
                number_partitions=>1::int,
                chunk_time_interval=>'07:57:57.345608'::interval,
                create_default_indexes=>false
            );
            PERFORM public.create_distributed_hypertable(
                '_ps_trace.event'::regclass,
                'time'::name,
                partitioning_column=>'trace_id'::name,
                number_partitions=>1::int,
                chunk_time_interval=>'07:59:53.649542'::interval,
                create_default_indexes=>false
            );
            PERFORM public.create_distributed_hypertable(
                '_ps_trace.link'::regclass,
                'span_start_time'::name,
                partitioning_column=>'trace_id'::name,
                number_partitions=>1::int,
                chunk_time_interval=>'07:59:48.644258'::interval,
                create_default_indexes=>false
            );
        ELSE -- not multinode
            PERFORM public.create_hypertable(
                '_ps_trace.span'::regclass,
                'start_time'::name,
                partitioning_column=>'trace_id'::name,
                number_partitions=>1::int,
                chunk_time_interval=>'07:57:57.345608'::interval,
                create_default_indexes=>false
            );
            PERFORM public.create_hypertable(
                '_ps_trace.event'::regclass,
                'time'::name,
                partitioning_column=>'trace_id'::name,
                number_partitions=>1::int,
                chunk_time_interval=>'07:59:53.649542'::interval,
                create_default_indexes=>false
            );
            PERFORM public.create_hypertable(
                '_ps_trace.link'::regclass,
                'span_start_time'::name,
                partitioning_column=>'trace_id'::name,
                number_partitions=>1::int,
                chunk_time_interval=>'07:59:48.644258'::interval,
                create_default_indexes=>false
            );
        END IF;

        IF (NOT _is_timescaledb_oss) AND _is_compression_available THEN
            -- turn on compression
            ALTER TABLE _ps_trace.span SET (timescaledb.compress, timescaledb.compress_segmentby='trace_id,span_id');
            ALTER TABLE _ps_trace.event SET (timescaledb.compress, timescaledb.compress_segmentby='trace_id,span_id');
            ALTER TABLE _ps_trace.link SET (timescaledb.compress, timescaledb.compress_segmentby='trace_id,span_id');

            IF _timescaledb_major_version < 2 THEN
                BEGIN
                    PERFORM public.add_compression_policy('_ps_trace.span', INTERVAL '1 hour');
                    PERFORM public.add_compression_policy('_ps_trace.event', INTERVAL '1 hour');
                    PERFORM public.add_compression_policy('_ps_trace.link', INTERVAL '1 hour');
                EXCEPTION
                    WHEN undefined_function THEN
                        RAISE NOTICE 'add_compression_policy does not exist';
                END;
            END IF;
        END IF;
    END IF;
END;
$block$
;
