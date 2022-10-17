CREATE TABLE _prom_catalog.rollup (
    name           TEXT NOT NULL PRIMARY KEY,
    schema_name    TEXT NOT NULL,
    resolution     INTERVAL NOT NULL,
    retention      INTERVAL NOT NULL
);
GRANT SELECT ON TABLE _prom_catalog.rollup TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _prom_catalog.rollup TO prom_writer;

CREATE TABLE _prom_catalog.metric_with_rollup (
    rollup_schema   TEXT,
    metric_name     TEXT,
    table_name      TEXT,
    refresh_pending BOOLEAN DEFAULT TRUE,
    PRIMARY KEY     (metric_name, table_name, rollup_schema)
);
GRANT SELECT ON TABLE _prom_catalog.metric_with_rollup TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _prom_catalog.metric_with_rollup TO prom_writer;