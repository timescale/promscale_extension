
-- {{filename}}
DO
$outer_migration_block$
DECLARE
    _migration_name TEXT = NULL;
    _body_differs BOOL = false;
    _migration _ps_catalog.migration = row ('{{filename}}', '{{version}}');
    _body TEXT = $migrationbody${{body}}$migrationbody$;
BEGIN
    SELECT migration.name, migration.body <> _body
    INTO _migration_name, _body_differs
    FROM _ps_catalog.migration
    WHERE name = _migration.name;
    IF _migration_name IS NOT NULL THEN
        RAISE LOG 'Migration "{{filename}}" already applied, skipping';
        -- 001-extension.sql changes are expected until this issue is resolved: https://github.com/timescale/promscale_extension/issues/350
        -- 024-adjust_autovacuum.sql had a bug in it and had to be changed
        IF _body_differs AND _migration_name != '001-extension.sql' and _migration_name != '024-adjust_autovacuum.sql' THEN
            RAISE WARNING 'The contents of migration "{{filename}}" have changed';
        END IF;
        RETURN;
    END IF;

-- Note: this weird indentation is important. We compare SQL across upgrade paths,
-- and the comparison is indentation-sensitive.
DO $inner_migration_block$
BEGIN
{{body}}
END;
$inner_migration_block$;

    INSERT INTO _ps_catalog.migration (name, applied_at_version, body) VALUES (_migration.name, _migration.applied_at_version, _body);
    RAISE LOG 'Applied migration {{filename}}';
END;
$outer_migration_block$;
