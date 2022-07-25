-- These type-related extension functions are not emitted by PGX, so must be
-- added to our idempotent scripts in order to point the functions at the most
-- recent version of our versioned extension binary.

-- src/aggregates/gapfill_delta.rs:29
-- promscale::aggregates::gapfill_delta::gapfilldeltatransition_in
CREATE OR REPLACE FUNCTION _prom_ext."gapfilldeltatransition_in"(
    "input" cstring /* &cstr_core::CStr */
) RETURNS _prom_ext.GapfillDeltaTransition /* promscale::aggregates::gapfill_delta::GapfillDeltaTransition */
    IMMUTABLE PARALLEL SAFE STRICT
    LANGUAGE c /* Rust */
AS '$libdir/promscale-0.5.5-dev', 'gapfilldeltatransition_in_wrapper';

-- src/aggregates/gapfill_delta.rs:29
-- promscale::aggregates::gapfill_delta::gapfilldeltatransition_out
CREATE OR REPLACE FUNCTION _prom_ext."gapfilldeltatransition_out"(
    "input" _prom_ext.GapfillDeltaTransition /* promscale::aggregates::gapfill_delta::GapfillDeltaTransition */
) RETURNS cstring /* &cstr_core::CStr */
    IMMUTABLE PARALLEL SAFE STRICT
    LANGUAGE c /* Rust */
AS '$libdir/promscale-0.5.5-dev', 'gapfilldeltatransition_out_wrapper';
