CREATE OR REPLACE FUNCTION @extschema@.prom_delta_transition(state internal, lowest_time timestamptz,
    greatest_time timestamptz, step bigint, range bigint,
    sample_time timestamptz, sample_value double precision)
RETURNS internal AS '$libdir/promscale', 'prom_delta_transition_wrapper'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION @extschema@.prom_rate_transition(state internal, lowest_time timestamptz,
    greatest_time timestamptz, step bigint, range bigint,
    sample_time timestamptz, sample_value double precision)
RETURNS internal AS '$libdir/promscale', 'prom_rate_transition_wrapper'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION @extschema@.prom_increase_transition(state internal, lowest_time timestamptz,
    greatest_time timestamptz, step bigint, range bigint,
    sample_time timestamptz, sample_value double precision)
RETURNS internal AS '$libdir/promscale', 'prom_increase_transition_wrapper'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION @extschema@.prom_extrapolate_final(state internal)
RETURNS DOUBLE PRECISION[]
AS '$libdir/promscale', 'prom_delta_final_wrapper'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION @extschema@."vector_selector_transition"("state" internal, "start_time" TimestampTz, "end_time" TimestampTz, "bucket_width" bigint, "lookback" bigint, "time" TimestampTz, "val" double precision) RETURNS internal IMMUTABLE PARALLEL SAFE LANGUAGE c AS 'MODULE_PATHNAME', 'vector_selector_transition_wrapper';
-- ./src/lib.rs:337:0
CREATE OR REPLACE FUNCTION @extschema@."vector_selector_final"("state" internal) RETURNS double precision[] IMMUTABLE PARALLEL SAFE LANGUAGE c AS 'MODULE_PATHNAME', 'vector_selector_final_wrapper';
-- ./src/lib.rs:345:0
CREATE OR REPLACE FUNCTION @extschema@."vector_selector_serialize"("state" internal) RETURNS bytea IMMUTABLE STRICT PARALLEL SAFE LANGUAGE c AS 'MODULE_PATHNAME', 'vector_selector_serialize_wrapper';
-- ./src/lib.rs:350:0
CREATE OR REPLACE FUNCTION @extschema@."vector_selector_deserialize"("bytes" bytea, "_internal" internal) RETURNS internal IMMUTABLE PARALLEL SAFE LANGUAGE c AS 'MODULE_PATHNAME', 'vector_selector_deserialize_wrapper';
-- ./src/lib.rs:358:0
CREATE OR REPLACE FUNCTION @extschema@."vector_selector_combine"("state1" internal, "state2" internal) RETURNS internal IMMUTABLE PARALLEL SAFE LANGUAGE c AS 'MODULE_PATHNAME', 'vector_selector_combine_wrapper';
CREATE AGGREGATE @extschema@.vector_selector(
    start_time timestamptz,
    end_time timestamptz,
    bucket_width bigint,
    lookback bigint,
    sample_time timestamptz,
    sample_value DOUBLE PRECISION)
(
    sfunc = vector_selector_transition,
    stype = internal,
    finalfunc = vector_selector_final,
    combinefunc = vector_selector_combine,
    serialfunc = vector_selector_serialize,
    deserialfunc = vector_selector_deserialize,
    parallel = safe
);