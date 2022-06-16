-- functions for trace_id custom type which is a wrapper around PG UUID type
CREATE OR REPLACE FUNCTION _ps_trace.trace_id_in(cstring)
RETURNS ps_trace.trace_id
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_in$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_in(cstring) TO prom_reader;
COMMENT ON FUNCTION _ps_trace.trace_id_in
IS 'This function is a part of custom ps_trace.tag_traceid type which is a wrapper for the built-in uuid. It is the same as its uuid_ namesake.';

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_out(ps_trace.trace_id)
RETURNS cstring
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_out$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_out(ps_trace.trace_id) TO prom_reader;
COMMENT ON FUNCTION _ps_trace.trace_id_out
IS 'This function is a part of custom ps_trace.tag_traceid type which is a wrapper for the built-in uuid. It is the same as its uuid_ namesake.';

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_send(ps_trace.trace_id)
RETURNS bytea
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_send$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_send(ps_trace.trace_id) TO prom_reader;
COMMENT ON FUNCTION _ps_trace.trace_id_send
IS 'This function is a part of custom ps_trace.tag_traceid type which is a wrapper for the built-in uuid. It is the same as its uuid_ namesake.';

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_recv(internal)
RETURNS ps_trace.trace_id
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_recv$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_recv(internal) TO prom_reader;
COMMENT ON FUNCTION _ps_trace.trace_id_recv
IS 'This function is a part of custom ps_trace.tag_traceid type which is a wrapper for the built-in uuid. It is the same as its uuid_ namesake.';

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_ne(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_ne$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_ne(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;
COMMENT ON FUNCTION _ps_trace.trace_id_ne
IS 'This function is a part of custom ps_trace.tag_traceid type which is a wrapper for the built-in uuid. It is the same as its uuid_ namesake.';

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_eq(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_eq$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_eq(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;
COMMENT ON FUNCTION _ps_trace.trace_id_eq
IS 'This function is a part of custom ps_trace.tag_traceid type which is a wrapper for the built-in uuid. It is the same as its uuid_ namesake.';

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_ge(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_ge$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_ge(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;
COMMENT ON FUNCTION _ps_trace.trace_id_ge
IS 'This function is a part of custom ps_trace.tag_traceid type which is a wrapper for the built-in uuid. It is the same as its uuid_ namesake.';

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_le(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_le$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_le(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;
COMMENT ON FUNCTION _ps_trace.trace_id_le
IS 'This function is a part of custom ps_trace.tag_traceid type which is a wrapper for the built-in uuid. It is the same as its uuid_ namesake.';

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_gt(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_gt$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_gt(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;
COMMENT ON FUNCTION _ps_trace.trace_id_gt
IS 'This function is a part of custom ps_trace.tag_traceid type which is a wrapper for the built-in uuid. It is the same as its uuid_ namesake.';

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_lt(ps_trace.trace_id, ps_trace.trace_id)
RETURNS bool
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_lt$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_lt(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;
COMMENT ON FUNCTION _ps_trace.trace_id_lt
IS 'This function is a part of custom ps_trace.tag_traceid type which is a wrapper for the built-in uuid. It is the same as its uuid_ namesake.';

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_cmp(ps_trace.trace_id, ps_trace.trace_id)
RETURNS int
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_cmp$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_cmp(ps_trace.trace_id, ps_trace.trace_id) TO prom_reader;
COMMENT ON FUNCTION _ps_trace.trace_id_cmp
IS 'This function is a part of custom ps_trace.tag_traceid type which is a wrapper for the built-in uuid. It is the same as its uuid_ namesake.';

CREATE OR REPLACE FUNCTION _ps_trace.trace_id_hash(ps_trace.trace_id)
RETURNS int
LANGUAGE internal
IMMUTABLE PARALLEL SAFE STRICT
AS $function$uuid_hash$function$;
GRANT EXECUTE ON FUNCTION _ps_trace.trace_id_hash(ps_trace.trace_id) TO prom_reader;
COMMENT ON FUNCTION _ps_trace.trace_id_hash
IS 'This function is a part of custom ps_trace.tag_traceid type which is a wrapper for the built-in uuid. It is the same as its uuid_ namesake.';
