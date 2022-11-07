CREATE TYPE _prom_ext.backend_telemetry_signal_type
    AS ENUM ('metrics', 'traces');

CREATE TYPE _prom_ext.backend_telemetry_job_type
    AS ENUM ('retention', 'compression');

CREATE TYPE _prom_ext.backend_telemetry_rec AS (
    time              timestamp with time zone,
    correlation_value BIGINT,
    signal_type       _prom_ext.backend_telemetry_signal_type,
    job_type          _prom_ext.backend_telemetry_job_type,
    tags              text[]
);