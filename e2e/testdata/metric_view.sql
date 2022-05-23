\set ECHO all
\set ON_ERROR_STOP 1

create extension promscale;

begin;
select _prom_catalog.get_or_create_metric_table_name(format('my_metric_%s', m))
from generate_series(1, 1000) m
;
commit;

call _prom_catalog.finalize_metric_creation();

do $block$
declare
    _metric text;
    _series_id bigint;
begin
    for _metric in
    (
        select format('my_metric_%s', m)
        from generate_series(1, 1000) m
    )
    loop
        -- create 1 series per metric
        select _prom_catalog.get_or_create_series_id(
            format('{"__name__": "%s", "namespace":"dev", "node": "brain"}', _metric)::jsonb
        ) into strict _series_id
        ;

        -- in the past - to be compressed
        execute format(
        $$
        insert into prom_data.%I
        select
            '1990-01-01'::timestamptz + (interval '1 hour' * x),
            x + 0.1,
            %s
        from generate_series(1, 250) x
        $$, _metric, _series_id
        );
        commit;

        -- compress the chunks
        execute format(
        $$
        select public.compress_chunk(public.show_chunks('prom_data.%I'))
        $$, _metric
        );
        commit;

        -- in the future - not compressed
        execute format(
        $$
        insert into prom_data.%I
        select
            '2035-01-01'::timestamptz + (interval '1 hour' * x),
            x + 0.1,
            %s
        from generate_series(1, 250) x
        $$, _metric, _series_id
        );
        commit;
    end loop;
end;
$block$;

select *
from prom_info.metric
order by id
;
