-- migration-table.sql
DO
$migration_table$
    DECLARE
        _current_user_id oid = NULL;
        _ps_catalog_schema_owner_id oid = NULL;
        _migration_table_owner_id text = NULL;
    BEGIN
        SELECT pg_user.usesysid
        INTO STRICT _current_user_id
        FROM pg_catalog.pg_user
        WHERE pg_user.usename = current_user;

        SELECT pg_namespace.nspowner
        INTO _ps_catalog_schema_owner_id
        FROM pg_catalog.pg_namespace
        WHERE pg_namespace.nspname = '_ps_catalog';

        IF _ps_catalog_schema_owner_id IS NOT NULL THEN
            IF _ps_catalog_schema_owner_id != _current_user_id  THEN
                -- We require that the superuser is the schema owner, otherwise
                -- there is a privilege escalation path available. We also know
                -- that the current user must be superuser, otherwise they
                -- wouldn't be able to install the extension.
                RAISE 'Only the owner of the "_ps_catalog" schema can install/upgrade this extension';
                RETURN;
            END IF;
            RAISE LOG 'Schema "_ps_catalog" is already present, skipping creation';
        ELSE
            CREATE SCHEMA _ps_catalog;
        END IF;

        SELECT pg_class.relowner
        INTO _migration_table_owner_id
        FROM pg_catalog.pg_class
          JOIN pg_catalog.pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        WHERE pg_class.relname = 'migration' AND pg_namespace.nspname = '_ps_catalog';

        IF _migration_table_owner_id IS NOT NULL THEN
            IF _migration_table_owner_id != _current_user_id THEN
                -- We require that the superuser owns this table, see above.
                RAISE 'Only the owner of the "_ps_catalog.migration" table can install/upgrade this extension';
                RETURN;
            END IF;
            RAISE LOG 'Table "_ps_catalog.migration" is already present, skipping creation';
        ELSE
            CREATE TABLE _ps_catalog.migration(
                  name TEXT NOT NULL PRIMARY KEY
                , applied_at_version TEXT
                , applied_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT clock_timestamp()
            );
        END IF;
    END;
$migration_table$;
