--perms for schema will be addressed later;
CREATE SCHEMA _prom_catalog;

--table to save commands so they can be run when adding new nodes
CREATE TABLE _prom_catalog.remote_commands(
    key TEXT PRIMARY KEY,
    seq SERIAL,
    transactional BOOLEAN,
    command TEXT
);
GRANT ALL ON SEQUENCE _prom_catalog.remote_commands_seq_seq TO current_user;

CREATE OR REPLACE PROCEDURE _prom_catalog.execute_everywhere(command_key text, command TEXT, transactional BOOLEAN = true)
    SET search_path = pg_catalog
AS $func$
DECLARE
    _is_restore_in_progress boolean = false;
BEGIN
    IF command_key IS NOT NULL THEN
       INSERT INTO _prom_catalog.remote_commands(key, command, transactional) VALUES(command_key, command, transactional)
       ON CONFLICT (key) DO UPDATE SET command = excluded.command, transactional = excluded.transactional;
    END IF;

    EXECUTE command;

    -- do not call distributed_exec if we are in the middle of restoring from backup
    _is_restore_in_progress = coalesce((SELECT setting = 'on' from pg_catalog.pg_settings where name = 'timescaledb.restoring'), false);
    IF _is_restore_in_progress THEN
        RAISE NOTICE 'restore in progress. skipping %', coalesce(command_key, 'anonymous command');
        RETURN;
    END IF;
    BEGIN
        CALL public.distributed_exec(command);
    EXCEPTION
        WHEN undefined_function THEN
            -- we're not on Timescale 2, just return
            RETURN;
        WHEN SQLSTATE '0A000' THEN
            -- we're not the access node, just return
            RETURN;
    END;
END
$func$ LANGUAGE PLPGSQL;
REVOKE ALL ON PROCEDURE _prom_catalog.execute_everywhere(text, text, boolean) FROM PUBLIC;

CREATE OR REPLACE PROCEDURE _prom_catalog.update_execute_everywhere_entry(command_key text, command TEXT, transactional BOOLEAN = true)
SET search_path = pg_catalog
AS $func$
BEGIN
    UPDATE _prom_catalog.remote_commands
    SET
        command=update_execute_everywhere_entry.command,
        transactional=update_execute_everywhere_entry.transactional
    WHERE key = command_key;
END
$func$ LANGUAGE PLPGSQL;
REVOKE ALL ON PROCEDURE _prom_catalog.update_execute_everywhere_entry(text, text, boolean) FROM PUBLIC;
