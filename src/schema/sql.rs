use pgx_macros::extension_sql_file;

extension_sql_file!("../../migration.sql", name = "migration", finalize);
