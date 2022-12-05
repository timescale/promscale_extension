ALTER TABLE _prom_catalog.metric ADD COLUMN view_refresh_interval INTERVAL DEFAULT NULL,
/*
A note for better visibility into the implementation.
We might have a question: Why do we need a rollup_id column when there exists a _prom_catalog.metric_rollup{metric_id <-> rollup_id} relation that
stores relationship between metric & their created rollups.

To understand this, we need to keep in mind that _prom_catalog.metric contains entries of 2 kinds:
1. Actual Prometheus metrics
2. Views registered by register_metric_view()

The entries under _prom_catalog.metric_rollup are from (1) only.

The reason we need to store rollup_id as separate column is to help us at the time of retention of Metric rollups or
the Custom Caggs created by the user.
If we do not store the rollup_id, we have no information regarding what is the retention interval of this rollup view entry in
the _prom_catalog.metric table while looping over it (WHERE is_view IS TRUE) during retention work.

One might think of using table_schema to figure out the matching rollup, but that does not really works for 2 reasons:
1. This approach is more of a hack
2. What happens to Custom Cagg views that are not rollup? We have no idea if these guys belong to a rollup or are they pure
     custom Caggs, hence we need some relationship with _prom_catalog.rollup table to at least understand which Cagg view is
     metric-rollup and which is a plain custom Cagg. This is because Custom Cagg have a separate retention duration than metric-rollups.
*/
    ADD COLUMN rollup_id BIGINT DEFAULT NULL,
    ADD CONSTRAINT fk_metric_rollup_id FOREIGN KEY (rollup_id) REFERENCES _prom_catalog.rollup(id);

-- Drop the prom_api.register_metric_view() due to definition change from (text, text, boolean) -> (text, text, interval, boolean, boolean).
DROP FUNCTION IF EXISTS prom_api.register_metric_view(text, text, boolean);