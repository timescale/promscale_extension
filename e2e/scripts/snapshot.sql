\pset pager off

select version();

\drds
\du
\dx
\dn
\dx+ promscale

-- dynamically generate meta commands to describe objects in the schemas
select format('%s %s', c.c, s.s)
from unnest(array
[ 'public.*'
, '_prom_catalog.*'
, '_prom_ext.*'
, '_ps_catalog.*'
, '_ps_trace.*'
, 'prom_api.*'
, 'prom_data.*'
, 'prom_data_exemplar.*'
, 'prom_data_series.*'
, 'prom_info.*'
, 'prom_metric.*'
, 'prom_series.*'
, 'ps_tag.*'
, 'ps_trace.*'
, '_timescaledb_cache'
, '_timescaledb_catalog'
, '_timescaledb_config'
, '_timescaledb_internal'
, 'timescaledb_experimental'
, 'timescaledb_information'
]) s(s)
cross join unnest(array
[ '\d+'
, '\df+'
, '\dp+'
, '\di'
, '\dy'
, '\do'
, '\dT'
, '\dS+'
]) c(c)
order by c.c, s.s
\g (tuples_only=on format=csv) describe.sql
\i describe.sql

-- snapshot the data from all the tables
select
    format($$select '%I.%I' as table_snapshot;$$, n.nspname, k.relname),
    case (n.nspname, k.relname)
        -- we don't care about comparing the applied_at_version and applied_at columns of the migration table
        when ('_ps_catalog'::name, 'migration'::name) then 'select name, body from _ps_catalog.migration;'
        else format('select * from %I.%I tbl order by tbl;', n.nspname, k.relname)
    end
from pg_namespace n
inner join pg_class k on (n.oid = k.relnamespace)
where k.relkind in ('r', 'p')
and n.nspname in
( 'public'
, '_prom_catalog'
, '_prom_ext'
, '_ps_catalog'
, '_ps_trace'
, 'prom_api'
, 'prom_data'
, 'prom_data_exemplar'
, 'prom_data_series'
, 'prom_info'
, 'prom_metric'
, 'prom_series'
, 'ps_tag'
, 'ps_trace'
)
order by n.nspname, k.relname
\gexec
