-- migration-table.sql
DO
$migration_table$
    DECLARE
        _schema_present bool = false;
    BEGIN
        SELECT count(*) FILTER (WHERE s.nspname = '_ps_catalog') > 0
        INTO STRICT _schema_present
        FROM pg_catalog.pg_namespace s;
        IF _schema_present THEN
            RAISE LOG 'Schema "_ps_catalog" is already present, skipping creation';
            RETURN;
        END IF;
        CREATE SCHEMA _ps_catalog;
        CREATE TABLE _ps_catalog.migration(
              name TEXT NOT NULL PRIMARY KEY
            , applied_at_version TEXT
            , applied_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
        );
    END;
$migration_table$;
