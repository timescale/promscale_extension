CREATE FUNCTION @extschema@.prom_delta_transition(state internal, lowest_time timestamptz,
    greatest_time timestamptz, step bigint, range bigint,
    sample_time timestamptz, sample_value double precision)
RETURNS internal AS '$libdir/promscale', 'prom_delta_transition_wrapper'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION @extschema@.prom_rate_transition(state internal, lowest_time timestamptz,
    greatest_time timestamptz, step bigint, range bigint,
    sample_time timestamptz, sample_value double precision)
RETURNS internal AS '$libdir/promscale', 'prom_rate_transition_wrapper'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION @extschema@.prom_increase_transition(state internal, lowest_time timestamptz,
    greatest_time timestamptz, step bigint, range bigint,
    sample_time timestamptz, sample_value double precision)
RETURNS internal AS '$libdir/promscale', 'prom_increase_transition_wrapper'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION @extschema@.prom_extrapolate_final(state internal)
RETURNS DOUBLE PRECISION[]
AS '$libdir/promscale', 'prom_delta_final_wrapper'
LANGUAGE C IMMUTABLE PARALLEL SAFE;