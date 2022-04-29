-- PG JIT compilation doesn't play nicely with TimescaleDB planner and can cause a huge 
-- slowdown for specific queries so we are turning it off.
-- We might revisit this once JIT issues are fixed in TimescaleDB */
DO $$
    BEGIN
        EXECUTE format('ALTER DATABASE %I SET jit = off', current_database());
    END
$$;
