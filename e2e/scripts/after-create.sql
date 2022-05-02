\set ECHO all
\set ON_ERROR_STOP 1

-- create a user named tsdbadmin
-- we will try to give tsdbadmin as few privileges as possible
-- and use tsdbadmin to do as much of the dump/restore process
-- as possible
do $block$
declare
    _version int;
begin
    select setting::int / 10000
    into strict _version
    from pg_settings where name = 'server_version_num';

    -- trusted extensions were introduced in postgres v13
    -- prior to that you must be a superuser to create extension
    if _version < 13 then
        create user tsdbadmin superuser;
    else
        create user tsdbadmin;
    end if;
end;
$block$;
alter database db owner to tsdbadmin;
grant all on database db to tsdbadmin;

create extension if not exists timescaledb with schema public;

-- the following code emulates what is done for privileges on cloud instances
-- https://github.com/timescale/timescaledb-docker-ha/blob/master/scripts/timescaledb/after-create.sql

-- The pre_restore and post_restore function can only be successfully executed by a very highly privileged
-- user. To ensure the database owner can also execute these functions, we have to alter them
-- from SECURITY INVOKER to SECURITY DEFINER functions. Setting the search_path explicitly is good practice
-- for SECURITY DEFINER functions.
-- As this function does have high impact, we do not want anyone to be able to execute the function,
-- but only the database owner.
ALTER FUNCTION public.timescaledb_pre_restore() SET search_path = pg_catalog,pg_temp SECURITY DEFINER;
ALTER FUNCTION public.timescaledb_post_restore() SET search_path = pg_catalog,pg_temp SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION public.timescaledb_pre_restore() FROM public;
REVOKE EXECUTE ON FUNCTION public.timescaledb_post_restore() FROM public;
GRANT EXECUTE ON FUNCTION public.timescaledb_pre_restore() TO tsdbadmin;
GRANT EXECUTE ON FUNCTION public.timescaledb_post_restore() TO tsdbadmin;

-- To reduce the errors seen on pg_restore we grant access to timescaledb internal tables
DO $$DECLARE r record;
BEGIN
    FOR r IN SELECT tsch from unnest(ARRAY['_timescaledb_internal', '_timescaledb_config', '_timescaledb_catalog', '_timescaledb_cache']) tsch
        LOOP
            EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA ' ||  quote_ident(r.tsch) || ' GRANT ALL PRIVILEGES ON TABLES TO tsdbadmin';
            EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA ' ||  quote_ident(r.tsch) || ' GRANT ALL PRIVILEGES ON SEQUENCES TO tsdbadmin';
            EXECUTE 'GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA ' ||  quote_ident(r.tsch) || ' TO tsdbadmin';
            EXECUTE 'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA ' ||  quote_ident(r.tsch) || ' TO tsdbadmin';
            EXECUTE 'GRANT USAGE, CREATE ON SCHEMA ' ||  quote_ident(r.tsch) || ' TO tsdbadmin';
        END LOOP;
END$$;
