
-- {{filename}}
DO $outer_idempotent_block$
DECLARE
    _old_search_path text;
BEGIN
    EXECUTE 'SHOW search_path' INTO STRICT _old_search_path;
    SET search_path TO pg_catalog;

-- Note: this weird indentation is important. We compare SQL across upgrade paths,
-- and the comparison is indentation-sensitive.
{{body}}

    EXECUTE format('SET search_path TO %s', _old_search_path);
    RAISE LOG 'Applied idempotent {{filename}}';
END;
$outer_idempotent_block$;
