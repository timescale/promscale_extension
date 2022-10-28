CREATE TABLE _prom_catalog.rollup (
    id             SERIAL PRIMARY KEY,
    name           TEXT NOT NULL,
    schema_name    TEXT NOT NULL,
    resolution     INTERVAL NOT NULL,
    retention      INTERVAL NOT NULL,
    UNIQUE(name)
);
GRANT SELECT ON TABLE _prom_catalog.rollup TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _prom_catalog.rollup TO prom_writer;

CREATE TABLE _prom_catalog.metric_rollup (
    id              SERIAL PRIMARY KEY,
    rollup_id       INTEGER NOT NULL,
    metric_id       INTEGER NOT NULL,
    refresh_pending BOOLEAN DEFAULT TRUE NOT NULL,
    UNIQUE (rollup_id, metric_id),
    FOREIGN KEY (rollup_id) REFERENCES _prom_catalog.rollup(id)
);
GRANT SELECT ON TABLE _prom_catalog.metric_rollup TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _prom_catalog.metric_rollup TO prom_writer;