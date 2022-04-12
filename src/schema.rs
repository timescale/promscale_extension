use pgx_macros::extension_sql_file;

extension_sql_file!("../bootstrap.sql", name = "bootstrap", bootstrap);

extension_sql_file!(
    "../hand-written-migration.sql",
    name = "migration",
    finalize
);
