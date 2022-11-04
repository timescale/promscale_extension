CREATE TYPE _prom_ext.backend_telemetry_rec AS (
    time timestamp with time zone,
    value BIGINT,
    tags text[]
);