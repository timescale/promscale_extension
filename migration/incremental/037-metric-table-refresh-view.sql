ALTER TABLE _prom_catalog.metric
    ADD COLUMN view_refresh_interval INTERVAL DEFAULT NULL,
/*
A note for better visibility into the implementation.
We might have a question: Why do we need a downsample_id column when there exists a _prom_catalog.metric_downsample{metric_id <-> downsample_id} relation that
stores relationship between metric & their created downsampled data.

To understand this, we need to keep in mind that _prom_catalog.metric contains entries of 2 kinds:
1. Actual Prometheus metrics
2. Views registered by register_metric_view()

The entries under _prom_catalog.metric_downsample are from (1) only.

The reason we need to store downsample_id as separate column is to help us at the time of retention of downsampled metric data or
the Custom Caggs created by the user.
If we do not store the downsample_id, we have no information regarding what is the retention interval of this downsampled view entry in
the _prom_catalog.metric table while looping over it (WHERE is_view IS TRUE) during retention work.

One might think of using table_schema to figure out the matching rollup, but that does not really works for 2 reasons:
1. This approach is more of a hack
2. What happens to Custom Cagg views that are not created by automatic-downsampling? We have no idea if these guys belong to
     automatic-downsampling or are they pure custom Caggs, hence we need some relationship with _prom_catalog.downsample
     table to at least understand which Cagg view is metric automatic-downsampling and which is a plain custom Cagg. This
     is because Custom Cagg have a separate retention duration than metric-rollups.
*/
    ADD COLUMN downsample_id BIGINT DEFAULT NULL,
    ADD CONSTRAINT fk_metric_downsample_id FOREIGN KEY (downsample_id) REFERENCES _prom_catalog.downsample(id);

-- Drop the prom_api.register_metric_view() due to definition change from (text, text, boolean) -> (text, text, interval, boolean, boolean).
DROP FUNCTION IF EXISTS prom_api.register_metric_view(text, text, boolean);