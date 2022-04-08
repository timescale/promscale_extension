
-- {{filename}}
DO
$outer_migration_block$
DECLARE
    _migration_name TEXT = NULL;
    _body_differs BOOL = false;
    _migration _ps_catalog.migration = row ('{{filename}}', '{{version}}');
    _body TEXT = $migrationbody${{body}}$migrationbody$;
    _old_search_path text;
BEGIN
    EXECUTE 'SHOW search_path' INTO STRICT _old_search_path;
    SET search_path TO pg_catalog;

    SELECT migration.name, migration.body <> _body
    INTO _migration_name, _body_differs
    FROM _ps_catalog.migration
    WHERE name = _migration.name;
    IF _migration_name IS NOT NULL THEN
        RAISE LOG 'Migration "{{filename}}" already applied, skipping';
        IF _body_differs THEN
            RAISE WARNING 'Checksum of migration "{{filename}}" has changed';
        END IF;
        EXECUTE format('SET search_path TO %s', _old_search_path);
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

    EXECUTE format('SET search_path TO %s', _old_search_path);
END;
$outer_migration_block$;
