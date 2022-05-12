select public.timescaledb_pre_restore();
create extension promscale; -- this MUST happen AFTER timescaledb_pre_restore!
