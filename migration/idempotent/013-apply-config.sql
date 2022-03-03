
DO $block$
DECLARE
    _schema text;
BEGIN
    FOR _schema IN
    (
        values
          ('_prom_catalog')
        , ('_prom_ext')
        , ('_ps_catalog')
        , ('_ps_trace')
        , ('prom_api')
        , ('prom_data')
        , ('prom_data_exemplar')
        , ('prom_data_series')
        , ('prom_info')
        , ('prom_metric')
        , ('prom_series')
        , ('ps_tag')
        , ('ps_trace')
    )
    LOOP
        EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA %I FROM PUBLIC', _schema);
        EXECUTE format('REVOKE ALL ON ALL PROCEDURES IN SCHEMA %I FROM PUBLIC', _schema);
    END LOOP;
END;
$block$;

DO $block$
DECLARE
    _table text;
BEGIN
    FOR _table IN
    (
        values
          ('_prom_catalog.default')
        , ('_prom_catalog.exemplar')
        , ('_prom_catalog.exemplar_label_key_position')
        , ('_prom_catalog.ha_leases')
        , ('_prom_catalog.ha_leases_logs')
        , ('_prom_catalog.ids_epoch')
        , ('_prom_catalog.label')
        , ('_prom_catalog.label_key')
        , ('_prom_catalog.label_key_position')
        , ('_prom_catalog.metadata')
        , ('_prom_catalog.metric')
        , ('_prom_catalog.remote_commands')
        , ('_ps_catalog.migration')
        , ('_ps_catalog.promscale_instance_information')
        , ('_ps_trace.event')
        , ('_ps_trace.instrumentation_lib')
        , ('_ps_trace.link')
        , ('_ps_trace.operation')
        , ('_ps_trace.schema_url')
        , ('_ps_trace.span')
        , ('_ps_trace.tag_1')
        , ('_ps_trace.tag_10')
        , ('_ps_trace.tag_11')
        , ('_ps_trace.tag_12')
        , ('_ps_trace.tag_13')
        , ('_ps_trace.tag_14')
        , ('_ps_trace.tag_15')
        , ('_ps_trace.tag_16')
        , ('_ps_trace.tag_17')
        , ('_ps_trace.tag_18')
        , ('_ps_trace.tag_19')
        , ('_ps_trace.tag_2')
        , ('_ps_trace.tag_20')
        , ('_ps_trace.tag_21')
        , ('_ps_trace.tag_22')
        , ('_ps_trace.tag_23')
        , ('_ps_trace.tag_24')
        , ('_ps_trace.tag_25')
        , ('_ps_trace.tag_26')
        , ('_ps_trace.tag_27')
        , ('_ps_trace.tag_28')
        , ('_ps_trace.tag_29')
        , ('_ps_trace.tag_3')
        , ('_ps_trace.tag_30')
        , ('_ps_trace.tag_31')
        , ('_ps_trace.tag_32')
        , ('_ps_trace.tag_33')
        , ('_ps_trace.tag_34')
        , ('_ps_trace.tag_35')
        , ('_ps_trace.tag_36')
        , ('_ps_trace.tag_37')
        , ('_ps_trace.tag_38')
        , ('_ps_trace.tag_39')
        , ('_ps_trace.tag_4')
        , ('_ps_trace.tag_40')
        , ('_ps_trace.tag_41')
        , ('_ps_trace.tag_42')
        , ('_ps_trace.tag_43')
        , ('_ps_trace.tag_44')
        , ('_ps_trace.tag_45')
        , ('_ps_trace.tag_46')
        , ('_ps_trace.tag_47')
        , ('_ps_trace.tag_48')
        , ('_ps_trace.tag_49')
        , ('_ps_trace.tag_5')
        , ('_ps_trace.tag_50')
        , ('_ps_trace.tag_51')
        , ('_ps_trace.tag_52')
        , ('_ps_trace.tag_53')
        , ('_ps_trace.tag_54')
        , ('_ps_trace.tag_55')
        , ('_ps_trace.tag_56')
        , ('_ps_trace.tag_57')
        , ('_ps_trace.tag_58')
        , ('_ps_trace.tag_59')
        , ('_ps_trace.tag_6')
        , ('_ps_trace.tag_60')
        , ('_ps_trace.tag_61')
        , ('_ps_trace.tag_62')
        , ('_ps_trace.tag_63')
        , ('_ps_trace.tag_64')
        , ('_ps_trace.tag_7')
        , ('_ps_trace.tag_8')
        , ('_ps_trace.tag_9')
        , ('_ps_trace.tag_key')
        , ('public.prom_installation_info')
    )
    LOOP
        EXECUTE format($sql$SELECT pg_catalog.pg_extension_config_dump(%L, '')$sql$, _table);
    END LOOP;
END;
$block$;
