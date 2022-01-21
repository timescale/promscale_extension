
-- {{filename}}
DO
$outer_migration_block$
    DECLARE
        _already_applied bool = false;
        _migration       _ps_catalog.migration = row ('{{filename}}', '{{version}}');
    BEGIN
        SELECT count(*) FILTER (WHERE name = _migration.name) > 0
        INTO STRICT _already_applied
        FROM _ps_catalog.migration;
        IF _already_applied THEN
            RAISE NOTICE 'Migration "{{filename}}" already applied';
            RETURN;
        END IF;

        DO
        $inner_migration_block$
            BEGIN
                {{body|indent(16)}}
            END;
        $inner_migration_block$;

        INSERT INTO _ps_catalog.migration (name, applied_at_version) VALUES (_migration.name, _migration.applied_at_version);
    END;
$outer_migration_block$;
