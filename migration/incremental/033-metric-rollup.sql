CREATE TABLE _prom_catalog.rollup (
    id             SERIAL,
    name           TEXT NOT NULL PRIMARY KEY,
    schema_name    TEXT NOT NULL,
    resolution     INTERVAL NOT NULL,
    retention      INTERVAL NOT NULL
);
GRANT SELECT ON TABLE _prom_catalog.rollup TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _prom_catalog.rollup TO prom_writer;

CREATE TABLE _prom_catalog.metric_rollup (
    id              SERIAL,
    rollup_id       INTEGER NOT NULL,
    metric_id       INTEGER NOT NULL,
    refresh_pending BOOLEAN DEFAULT TRUE NOT NULL,
    PRIMARY KEY     (rollup_id, metric_id)
);
GRANT SELECT ON TABLE _prom_catalog.metric_rollup TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _prom_catalog.metric_rollup TO prom_writer;