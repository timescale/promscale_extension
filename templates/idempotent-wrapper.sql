
-- {{filename}}
DO
$outer_migration_block$
    BEGIN
        {{body|indent(8)}}
    END;
$outer_migration_block$;
