-- Create a metric along with its metadata and insert some samples.
DO $$
BEGIN
    PERFORM _prom_catalog.get_or_create_metric_table_name('test');
INSERT INTO _prom_catalog.metadata VALUES (to_timestamp(0), 'test', 'GAUGE', '', 'Test metric.');

-- Insert samples for 1 month.
INSERT INTO prom_data.test
SELECT
    time,
    floor(random()*1000) AS value,
    _prom_catalog.get_or_create_series_id('{"__name__": "test", "job":"promscale", "instance": "localhost:9090"}')
FROM generate_series(
    '2022-10-01 00:00:00',
    '2022-10-08 00:00:00',
    interval '30 seconds'
) as time;
END;
$$;