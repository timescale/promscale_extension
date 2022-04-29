create user bob;
alter database db owner to bob;
grant all on database db to bob;

set role bob;
create extension if not exists timescaledb with schema public;
create extension if not exists promscale;

reset role;
select public.timescaledb_pre_restore();
