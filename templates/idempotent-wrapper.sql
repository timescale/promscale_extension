
-- {{filename}}
DO
$outer_idempotent_block$
    BEGIN
        {{body|indent(8)}}
        RAISE LOG 'Applied idempotent {{filename}}';
    END;
$outer_idempotent_block$;
