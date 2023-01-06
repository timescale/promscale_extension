\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(13);

SELECT ok(count(*) = 0) FROM _prom_catalog.downsample;

-- Create a downsampling config.
SELECT _prom_catalog.apply_downsample_config($$[{"schema_name": "ds_5m", "ds_interval": "5m", "retention": "30d"}]$$::jsonb);
SELECT ok(count(*) = 1) FROM _prom_catalog.downsample WHERE schema_name = 'ds_5m' AND should_refresh;

-- Create another downsampling config.
SELECT _prom_catalog.apply_downsample_config($$
    [
        {"schema_name": "ds_5m", "ds_interval": "5m", "retention": "30d"},
        {"schema_name": "ds_1h", "ds_interval": "1h", "retention": "365d"}
    ]
$$::jsonb);
SELECT ok(count(*) = 1) FROM _prom_catalog.downsample WHERE schema_name = 'ds_1h' AND should_refresh;
SELECT ok(count(*) = 2) FROM _prom_catalog.downsample WHERE should_refresh;

-- Remove the ds_5m and see if its disabled.
SELECT _prom_catalog.apply_downsample_config($$
    [
        {"schema_name": "ds_1h", "ds_interval": "1h", "retention": "365d"}
    ]
$$::jsonb);
SELECT ok(should_refresh = false) FROM _prom_catalog.downsample WHERE schema_name = 'ds_5m';
SELECT ok(count(*) = 2) FROM _prom_catalog.downsample; -- We should still have 2 configs.

-- Update retention of ds_1h and check if the same is reflected.
SELECT ok(retention = INTERVAL '365 days') FROM _prom_catalog.downsample WHERE schema_name = 'ds_1h' AND should_refresh;
SELECT _prom_catalog.apply_downsample_config($$
    [
        {"schema_name": "ds_1h", "ds_interval": "1h", "retention": "500d"}
    ]
$$::jsonb);
SELECT ok(retention = INTERVAL '500 days') FROM _prom_catalog.downsample WHERE schema_name = 'ds_1h' AND should_refresh;
SELECT ok(count(*) = 2) FROM _prom_catalog.downsample; -- We should still have 2 configs.
SELECT ok(should_refresh = false) FROM _prom_catalog.downsample WHERE schema_name = 'ds_5m'; -- ds_5m should still be untouched.

-- Enable the ds_5m downsampling that was already present.
SELECT _prom_catalog.apply_downsample_config($$
    [
        {"schema_name": "ds_5m", "ds_interval": "5m", "retention": "30d"},
        {"schema_name": "ds_1h", "ds_interval": "1h", "retention": "500d"}
    ]
$$::jsonb);
SELECT ok(should_refresh = true) FROM _prom_catalog.downsample WHERE schema_name = 'ds_5m';
SELECT ok(count(*) = 2) FROM _prom_catalog.downsample;

-- Change the ds_interval of ds_5m to a same value but with different unit. We should expect an error now.
PREPARE thrower AS
    SELECT _prom_catalog.apply_downsample_config($$
        [
            {"schema_name": "ds_300s", "ds_interval": "300s", "retention": "30d"},
            {"schema_name": "ds_1h", "ds_interval": "1h", "retention": "500d"}
        ]
    $$::jsonb);
SELECT throws_ok(
    'thrower',
    '23505',
    'duplicate key value violates unique constraint "downsample_ds_interval_key"'
);

SELECT * FROM finish(true);
