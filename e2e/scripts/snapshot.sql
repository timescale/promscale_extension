\pset pager off
\drds
\du
\dx
\dn
\dx+ promscale

-- tables
\d+ public.*
\d+ _prom_catalog.*
\d+ _prom_ext.*
\d+ _ps_catalog.*
\d+ _ps_trace.*
\d+ prom_api.*
\d+ prom_data.*
\d+ prom_data_exemplar.*
\d+ prom_data_series.*
\d+ prom_info.*
\d+ prom_metric.*
\d+ prom_series.*
\d+ ps_tag.*
\d+ ps_trace.*

-- functions
\df+ public.*
\df+ _prom_catalog.*
\df+ _prom_ext.*
\df+ _ps_catalog.*
\df+ _ps_trace.*
\df+ prom_api.*
\df+ prom_data.*
\df+ prom_data_exemplar.*
\df+ prom_data_series.*
\df+ prom_info.*
\df+ prom_metric.*
\df+ prom_series.*
\df+ ps_tag.*
\df+ ps_trace.*

-- privileges
\dp+ public.*
\dp+ _prom_catalog.*
\dp+ _prom_ext.*
\dp+ _ps_catalog.*
\dp+ _ps_trace.*
\dp+ prom_api.*
\dp+ prom_data.*
\dp+ prom_data_exemplar.*
\dp+ prom_data_series.*
\dp+ prom_info.*
\dp+ prom_metric.*
\dp+ prom_series.*
\dp+ ps_tag.*
\dp+ ps_trace.*

-- indicies
\di public.*
\di _prom_catalog.*
\di _prom_ext.*
\di _ps_catalog.*
\di _ps_trace.*
\di prom_api.*
\di prom_data.*
\di prom_data_exemplar.*
\di prom_data_series.*
\di prom_info.*
\di prom_metric.*
\di prom_series.*
\di ps_tag.*
\di ps_trace.*

-- triggers
\dy public.*
\dy _prom_catalog.*
\dy _prom_ext.*
\dy _ps_catalog.*
\dy _ps_trace.*
\dy prom_api.*
\dy prom_data.*
\dy prom_data_exemplar.*
\dy prom_data_series.*
\dy prom_info.*
\dy prom_metric.*
\dy prom_series.*
\dy ps_tag.*
\dy ps_trace.*

-- operators
\do public.*
\do _prom_catalog.*
\do _prom_ext.*
\do _ps_catalog.*
\do _ps_trace.*
\do prom_api.*
\do prom_data.*
\do prom_data_exemplar.*
\do prom_data_series.*
\do prom_info.*
\do prom_metric.*
\do prom_series.*
\do ps_tag.*
\do ps_trace.*

-- snapshot the data from all the tables
select
    format($$select '%I.%I' as table_snapshot;$$, n.nspname, k.relname),
    case (n.nspname, k.relname)
        -- we don't care about comparing the applied_at_version and applied_at columns of the migration table
        when ('_ps_catalog'::name, 'migration'::name) then 'select name, body from _ps_catalog.migration;'
        else format('select * from %I.%I;', n.nspname, k.relname)
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
