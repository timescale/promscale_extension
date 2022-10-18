DO $block$
BEGIN
    DROP VIEW IF EXISTS prom_info.metric;
    DROP FUNCTION IF EXISTS _prom_catalog.metric_view();
EXCEPTION WHEN dependent_objects_still_exist THEN
    RAISE EXCEPTION dependent_objects_still_exist USING
        DETAIL = 'The signature of prom_info.metric is changing. ' ||
        'Dependent objects need to be dropped before the upgrade, and recreated afterwards.',
        HINT = 'Drop any objects that depend on prom_info.metric'
        ;
END;
$block$;
