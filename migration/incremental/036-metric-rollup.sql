CREATE TABLE _prom_catalog.downsample (
    id             SERIAL PRIMARY KEY,
    schema_name    TEXT NOT NULL,
    resolution     INTERVAL NOT NULL,
    retention      INTERVAL NOT NULL,
    should_refresh BOOLEAN DEFAULT FALSE,
    UNIQUE(schema_name)
);
GRANT SELECT ON TABLE _prom_catalog.downsample TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _prom_catalog.downsample TO prom_writer;

CREATE TABLE _prom_catalog.metric_downsample (
    id              SERIAL PRIMARY KEY,
    downsample_id   INTEGER NOT NULL,
    metric_id       INTEGER NOT NULL,
    refresh_pending BOOLEAN DEFAULT TRUE NOT NULL,
    UNIQUE (downsample_id, metric_id),
    FOREIGN KEY (downsample_id) REFERENCES _prom_catalog.downsample(id)
);
GRANT SELECT ON TABLE _prom_catalog.metric_downsample TO prom_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE _prom_catalog.metric_downsample TO prom_writer;