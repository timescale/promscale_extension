create user bob;
grant all on database db to bob;
grant postgres to bob; -- todo: bob should not need postgres role

-- todo: set role bob;
create extension if not exists timescaledb;
select public.timescaledb_pre_restore();
create extension if not exists promscale;
