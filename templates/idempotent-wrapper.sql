
-- {{filename}}
DO $outer_idempotent_block$
BEGIN

-- Note: this weird indentation is important. We compare SQL across upgrade paths,
-- and the comparison is indentation-sensitive.
{{body}}

END;
$outer_idempotent_block$;
