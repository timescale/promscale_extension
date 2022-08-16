/* Initially a set of operators were defined for the btree-opclass.
 * Those caused type coercion conflicts with operators intended to be
 * used with tag_v.
 * Here we drop those operators and other objects created by pg implicitly
 */

DROP OPERATOR IF EXISTS ps_trace.= (_ps_trace.tag_v, _ps_trace.tag_v) CASCADE;
DROP OPERATOR IF EXISTS ps_trace.<> (_ps_trace.tag_v, _ps_trace.tag_v)  CASCADE;
DROP OPERATOR IF EXISTS ps_trace.> (_ps_trace.tag_v, _ps_trace.tag_v) CASCADE;
DROP OPERATOR IF EXISTS ps_trace.>= (_ps_trace.tag_v, _ps_trace.tag_v) CASCADE;
DROP OPERATOR IF EXISTS ps_trace.< (_ps_trace.tag_v, _ps_trace.tag_v) CASCADE;
DROP OPERATOR IF EXISTS ps_trace.<= (_ps_trace.tag_v, _ps_trace.tag_v) CASCADE;

DROP OPERATOR CLASS IF EXISTS public.btree_tag_v_ops USING btree;
DROP OPERATOR FAMILY IF EXISTS public.btree_tag_v_ops USING btree;
