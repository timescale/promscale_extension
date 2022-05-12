-- We had these operators in the private _prom_catalog schema instead of the
-- public prom_api schema. With the new (restricted) search path, we need to
-- move these.
ALTER OPERATOR _prom_catalog.? (prom_api.label_array, ps_tag.tag_op_equals) SET SCHEMA prom_api;
ALTER OPERATOR _prom_catalog.? (prom_api.label_array, ps_tag.tag_op_not_equals) SET SCHEMA prom_api;
ALTER OPERATOR _prom_catalog.? (prom_api.label_array, ps_tag.tag_op_regexp_matches) SET SCHEMA prom_api;
ALTER OPERATOR _prom_catalog.? (prom_api.label_array, ps_tag.tag_op_regexp_not_matches) SET SCHEMA prom_api;

-- Setup the database-wide search path, so that users who want to interact with
-- the promscale extension's SQL objects are able to do so without much fuss.
DO $$
    DECLARE
        base_components TEXT[];
        new_components TEXT[];
        final_components TEXT[];
        new_path TEXT;
    BEGIN
        -- we use the `reset_val` for `search_path` as the "clean" base of our search path
        SELECT regexp_split_to_array(reset_val, ',\s*') FROM pg_settings WHERE name = 'search_path' INTO base_components;
        -- we only want to add our components to the search path if they're not already in there
        WITH only_new_components AS (
            SELECT UNNEST(ARRAY ['ps_tag', 'prom_api', 'prom_metric', 'ps_trace']) as v
            EXCEPT
            SELECT UNNEST(base_components) as v
        )
        SELECT array_agg(v) FROM only_new_components INTO new_components;

        final_components := base_components || new_components;

        SELECT array_to_string(final_components, ', ') INTO new_path;
        EXECUTE format('ALTER DATABASE %I SET search_path = %s', current_database(), new_path);
        EXECUTE format('SET search_path = %s', new_path);
    END
$$;
