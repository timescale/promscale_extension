
-- {{filename}}
DO $outer_idempotent_block$
BEGIN
{{body}}
RAISE LOG 'Applied idempotent {{filename}}';
END;
$outer_idempotent_block$;
