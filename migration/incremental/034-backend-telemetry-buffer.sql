CREATE TYPE _prom_ext.backend_telemetry_signal_type
    AS ENUM ('metrics', 'traces');
GRANT USAGE ON TYPE _prom_ext.backend_telemetry_signal_type TO prom_reader;

CREATE TYPE _prom_ext.backend_telemetry_job_type
    AS ENUM ('retention', 'compression');
GRANT USAGE ON TYPE _prom_ext.backend_telemetry_job_type TO prom_reader;

CREATE TYPE _prom_ext.backend_telemetry_rec AS 
(
    time              timestamp with time zone,
    correlation_value BIGINT,
    signal_type       _prom_ext.backend_telemetry_signal_type,
    job_type          _prom_ext.backend_telemetry_job_type,
    tags              text[]
);
GRANT USAGE ON TYPE _prom_ext.backend_telemetry_job_type TO prom_reader;

CREATE SEQUENCE IF NOT EXISTS _ps_catalog.job_telemetry_corr_id START 1;
GRANT USAGE ON SEQUENCE _ps_catalog.job_telemetry_corr_id TO prom_maintenance, prom_admin;

CREATE TABLE IF NOT EXISTS _ps_catalog.job_telemetry 
(
    signal_type _prom_ext.backend_telemetry_signal_type,
    job_type _prom_ext.backend_telemetry_job_type,
    last_duration INTERVAL DEFAULT '0 seconds'::INTERVAL,
    failures BIGINT DEFAULT 0,
    total_runs BIGINT DEFAULT 0,
    PRIMARY KEY (signal_type, job_type)
);
GRANT SELECT ON TABLE _ps_catalog.job_telemetry TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _ps_catalog.job_telemetry 
TO prom_maintenance, prom_admin;

CREATE TYPE _ps_catalog.job_telemetry_scope AS 
(
    signal_type _prom_ext.backend_telemetry_signal_type,
    job_type    _prom_ext.backend_telemetry_job_type,
    corr_id     BIGINT
);
GRANT USAGE ON TYPE _ps_catalog.job_telemetry_scope TO prom_reader;