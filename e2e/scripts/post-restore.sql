select public.timescaledb_post_restore();
set timescaledb.restoring to 'off'; -- timescaledb bug https://github.com/timescale/timescaledb/issues/4267
select _timescaledb_internal.restart_background_workers(); -- timescaledb bug https://github.com/timescale/timescaledb/issues/4267
select public.promscale_post_restore();
