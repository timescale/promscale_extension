use pgx::*;

// Set the search path to one that will find all the definitions provided by the
// connector. Since the connector can change the schemas it stores things
// in we cannot just hardcode the searchpath, instead we switch the search path
// based on the schemas declared by the connector.
extension_sql!(
    r#"
DO $$
    DECLARE
        ext_schema TEXT;
        prom_schema TEXT;
        metric_schema TEXT;
        catalog_schema TEXT;
        new_path TEXT;
    BEGIN
        -- SELECT value FROM public.prom_installation_info
        --  WHERE key = 'extension schema'
        --   INTO ext_schema;
        -- SELECT value FROM public.prom_installation_info
        --  WHERE key = 'prometheus API schema'
        --   INTO prom_schema;
        -- SELECT value FROM public.prom_installation_info
        --  WHERE key = 'catalog schema'
        --   INTO catalog_schema;
        -- new_path := format('public,%s,%s,%s', ext_schema, prom_schema, catalog_schema);
        -- PERFORM set_config('search_path', new_path, false);
    END
$$;
"#,
    name = "configure_searchpath",
    bootstrap
);
