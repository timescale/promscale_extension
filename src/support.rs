use pgx::*;

#[pg_schema]
mod _prom_ext {
    use crate::palloc::{PallocdString, ToInternal};
    use crate::pg_imports::*;
    use crate::*;
    use std::ffi::CString;
    use std::ptr;

    /// This [support function] optimizes calls to the supported function if it's
    /// called with constant-like arguments. Such calls are transformed into a
    /// subquery of the function call. This allows the planner to make this call an
    /// InitPlan which is evaluated once per query instead of multiple times
    /// (e.g. on every tuple when the function is used in a WHERE clause).
    ///
    /// Assuming the presence of a supported function `supported_fn(text, text)`,
    /// a query such as the following:
    ///
    /// ```sql
    /// SELECT * FROM some_table WHERE supported_fn('constant', 'parameters');
    /// ```
    ///
    /// Will be transformed into the following by this support function:
    ///
    /// ```sql
    /// SELECT * FROM some_table WHERE (SELECT supported_fn('constant', 'parameters'));
    /// ```
    ///
    /// This should be used on any stable function that is often called with constant-like
    /// arguments.
    ///
    /// [support function]: https://www.postgresql.org/docs/current/xfunc-optimization.html
    #[pg_extern(immutable, strict)]
    pub unsafe fn rewrite_fn_call_to_subquery(input: Internal) -> Internal {
        let req = if let Some(r) = extract_simplify_request(input) {
            r
        } else {
            return ptr::null_mut::<pg_sys::Node>().internal();
        };
        let root = (*req).root;
        let expr = (*req).fcall;
        let original_args = PgList::<pg_sys::Node>::from_pg((*expr).args);

        // Check that these are expressions that don't reference any vars,
        // i.e. they are constants or expressions of constants
        let args_are_constants = original_args
            .iter_ptr()
            .all(|arg| arg_can_be_put_into_subquery(arg));
        if !args_are_constants {
            return ptr::null_mut::<pg_sys::Node>().internal();
        }

        (*(*root).parse).hasSubLinks = true;

        let f2: *mut pg_sys::FuncExpr =
            pg_sys::copyObjectImpl(expr as *const ::std::os::raw::c_void) as *mut pg_sys::FuncExpr;

        let mut te = PgBox::<pg_sys::TargetEntry>::alloc_node(pg_sys::NodeTag_T_TargetEntry);
        te.expr = f2 as *mut pg_sys::Expr;
        te.resno = 1;

        let mut query = PgBox::<pg_sys::Query>::alloc_node(pg_sys::NodeTag_T_Query);
        query.commandType = pg_sys::CmdType_CMD_SELECT;
        query.jointree =
            PgBox::<pg_sys::FromExpr>::alloc_node(pg_sys::NodeTag_T_FromExpr).into_pg();
        query.canSetTag = true;

        let mut list = PgList::<pg_sys::TargetEntry>::new();
        list.push(te.into_pg() as *mut pg_sys::TargetEntry);

        query.targetList = list.into_pg();

        let mut sublink = PgBox::<pg_sys::SubLink>::alloc_node(pg_sys::NodeTag_T_SubLink);
        sublink.subLinkType = pg_sys::SubLinkType_EXPR_SUBLINK;
        sublink.subLinkId = 0;
        sublink.subselect = query.into_pg() as *mut pg_sys::Node;

        (sublink.into_pg() as *mut pg_sys::Node).internal()
    }

    /// Backwards compatibility
    #[no_mangle]
    pub extern "C" fn pg_finfo_make_call_subquery_support() -> &'static pg_sys::Pg_finfo_record {
        const V1_API: pg_sys::Pg_finfo_record = pg_sys::Pg_finfo_record { api_version: 1 };
        &V1_API
    }

    #[no_mangle]
    pub unsafe extern "C" fn make_call_subquery_support(
        fcinfo: pg_sys::FunctionCallInfo,
    ) -> pg_sys::Datum {
        rewrite_fn_call_to_subquery_wrapper(fcinfo)
    }

    pub unsafe fn arg_can_be_put_into_subquery(arg: *mut pg_sys::Node) -> bool {
        if pgx::is_a(arg, pg_sys::NodeTag_T_Const) {
            return true;
        }

        if pgx::is_a(arg, pg_sys::NodeTag_T_CoerceToDomain) {
            let domain = arg.cast::<pg_sys::CoerceToDomain>();
            return arg_can_be_put_into_subquery((*domain).arg as *mut pg_sys::Node);
        }

        false
    }

    const DENORMALIZE_FUNC_NAME: &str = "tag_map_denormalize";
    const ARROW_OP_NAME: &str = "->";
    const HELPER_FUNC_SCHEMA: &str = "_ps_trace";
    const CONTAINS_OP_PATH: [&str; 2] = ["pg_catalog", "@>"];
    /// This support function expects an expression in the following form:
    /// ```sql
    /// SELECT * FROM some_table
    /// WHERE tag_map_denormalize(map_attribute) -> key OP value;
    /// ```
    /// where `OP` could be any binary operator this function is attached to.
    /// For a given operator `OP` the name of its underlying function is used
    /// to locate a corresponding helper function: `_ps_trace.OP_FUNC_rewrite_helper`.
    /// E.g. for operator `=` backed by function `tag_v_eq` the helper function
    /// will be `_ps_trace.tag_v_eq_rewrite_helper`.
    ///
    /// If input expression matches the expected form, it will be rewritten as:
    /// ```sql
    /// SELECT * FROM some_table
    /// WHERE map_attribute @> _ps_trace.OP_rewrite_helper(key, value)
    /// ```
    ///
    /// Furthermore, if both `key` and `value` are constant expressions,
    /// [`rewrite_fn_call_to_subquery`] will be used on the rhs to further optimize it:
    /// ```sql
    /// SELECT * FROM some_table
    /// WHERE map_attribute @> (SELECT _ps_trace.OP_rewrite_helper(key, value))
    /// ```
    #[pg_extern(immutable, strict)]
    pub unsafe fn tag_map_rewrite(input: Internal) -> Internal {
        // Wrapping core logic into a funciton, that returns a Result,
        // thus enabling .ok_or(...)? shorthand for dealing with optionals.
        unsafe fn inner(input: Internal) -> Result<Internal, ()> {
            let req = extract_simplify_request(input).ok_or(())?;

            // Deconstructing the top level operator:
            // tag_map_denormalize(any_tag_map_attribute) -> key OP const_value
            // ^- op_arg_left ---------------------------------^    ^- op_arg_right
            let op_func_expr = (*req).fcall;
            let original_args = PgList::<pg_sys::Node>::from_pg((*op_func_expr).args);
            // when -> is a regular operator (as opposed to our own special one),
            // there might be a domain coercion node.
            let op_arg_left = strip_type_coercion(original_args.head().ok_or(())?);
            let op_arg_right = original_args.tail().ok_or(())?;

            // Deconstructing the -> operator
            // tag_map_denormalize(any_tag_map_attribute) -> key
            // ^- arrow_op_arg_left                          ^- arrow_op_arg_right
            if !pgx::is_a(op_arg_left, pg_sys::NodeTag_T_OpExpr) {
                return Err(());
            }
            // the operator is indeed ->
            let arrow_op = op_arg_left.cast::<pg_sys::OpExpr>();
            let arrow_op_name_const = CString::new(ARROW_OP_NAME).unwrap();
            PallocdString::from_ptr(pg_sys::get_opname((*arrow_op).opno))
                .filter(|op_name| op_name.as_c_str() == arrow_op_name_const.as_c_str())
                .ok_or(())?;
            // extract operator's args
            let arrow_args = PgList::<pg_sys::Node>::from_pg((*arrow_op).args);
            let arrow_op_arg_left = strip_type_coercion(arrow_args.head().ok_or(())?);
            let arrow_op_arg_right = arrow_args.tail().ok_or(())?;

            // Deconstructing the func call to tag_map_denormalize
            // and extracting its argument.
            if !pgx::is_a(arrow_op_arg_left, pg_sys::NodeTag_T_FuncExpr) {
                return Err(());
            }
            // Validate the funciton is indeed tag_map_denormalize
            let denormalize_func = arrow_op_arg_left.cast::<pg_sys::FuncExpr>();
            let denormalize_name = CString::new(DENORMALIZE_FUNC_NAME).unwrap();
            PallocdString::from_ptr(pg_sys::get_func_name((*denormalize_func).funcid))
                .filter(|fname| fname.as_c_str() == denormalize_name.as_c_str())
                .ok_or(())?;
            // extract its argument
            let denormalize_args = PgList::<pg_sys::Node>::from_pg((*denormalize_func).args);
            let denormalize_arg = denormalize_args.head().ok_or(())?;

            // Locate the helper function
            let top_level_func_name_box =
                PallocdString::from_ptr(pg_sys::get_func_name((*op_func_expr).funcid)).ok_or(())?;
            let top_level_func_name = top_level_func_name_box
                .as_c_str()
                .to_str()
                .expect("Non-UTF8 function name");
            let helper_func_name = format!("{}_rewrite_helper", top_level_func_name);
            let helper_func_detail = func_get_detail(
                [HELPER_FUNC_SCHEMA, &helper_func_name],
                &mut [pg_sys::TEXTOID, pg_sys::JSONBOID],
            );
            if helper_func_detail.code == pg_sys::FuncDetailCode_FUNCDETAIL_NOTFOUND {
                pgx::warning!(
                    "Couldn't find helper function: {}.{}",
                    HELPER_FUNC_SCHEMA,
                    helper_func_name
                );
                return Err(());
            }
            if helper_func_detail.code != pg_sys::FuncDetailCode_FUNCDETAIL_NORMAL {
                pgx::error!(
                    "Expected helper function {}.{} to be a regular function",
                    HELPER_FUNC_SCHEMA,
                    helper_func_name
                );
            }

            // Locate @> jsonb operator
            let jsonb_contains_fully_qualified_name = build_pg_list_of_strings(CONTAINS_OP_PATH);
            let jsonb_contains_op_oid = LookupOperName(
                std::ptr::null_mut(),
                jsonb_contains_fully_qualified_name.into_pg(),
                pg_sys::JSONBOID,
                pg_sys::JSONBOID,
                false, // Raises an error if the operator is not found
                -1,
            );

            // Make a planner node for the helper function call
            let mut helper_func_args = PgList::new();
            helper_func_args.push(arrow_op_arg_right);
            helper_func_args.push(op_arg_right);
            let helper_func_expr = pg_sys::makeFuncExpr(
                helper_func_detail.func_oid,
                helper_func_detail.ret_type_oid,
                helper_func_args.into_pg(),
                (*op_func_expr).funccollid,
                (*op_func_expr).inputcollid,
                pg_sys::CoercionForm_COERCE_EXPLICIT_CALL,
            );

            // Make an attempt to move the function call into an InitPlan
            // by calling [`rewrite_fn_call_to_subquery`]
            let mut sub_simplify_req = pg_sys::SupportRequestSimplify {
                type_: pg_sys::NodeTag_T_SupportRequestSimplify,
                root: (*req).root,
                fcall: helper_func_expr,
            };
            let helper_expr_init_plan = fcinfo::direct_pg_extern_function_call_as_datum(
                rewrite_fn_call_to_subquery_wrapper,
                vec![
                    (&mut sub_simplify_req as *mut pg_sys::SupportRequestSimplify)
                        .internal()
                        .into_datum(),
                ],
            )
            .map(|datum: pg_sys::Datum| datum as *mut pg_sys::FuncExpr)
            .filter(|&expr| !expr.is_null())
            .unwrap_or(helper_func_expr);

            // Make a planner node for the @> operator (this is our new root)
            let contains_op_expr = pg_sys::make_opclause(
                jsonb_contains_op_oid,
                pg_sys::BOOLOID,
                false, // not a set returning operator
                denormalize_arg.cast::<pg_sys::Expr>(),
                helper_expr_init_plan.cast::<pg_sys::Expr>(),
                (*op_func_expr).funccollid,
                (*op_func_expr).inputcollid,
            );

            Ok(contains_op_expr.internal())
        }

        match inner(input) {
            Ok(res) => res,
            Err(_) => ptr::null_mut::<pg_sys::Node>().internal(),
        }
    }

    /// Returns a sub-node if passed argument is a type coercing or a relabel node,
    /// otherwise returns its argument as is.
    fn strip_type_coercion(expr: *mut pg_sys::Node) -> *mut pg_sys::Node {
        unsafe {
            if pgx::is_a(expr, pg_sys::NodeTag_T_CoerceToDomain) {
                let coercion = expr.cast::<pg_sys::CoerceToDomain>();
                (*coercion).arg.cast::<pg_sys::Node>()
            } else if pgx::is_a(expr, pg_sys::NodeTag_T_RelabelType) {
                let relabel = expr.cast::<pg_sys::RelabelType>();
                (*relabel).arg.cast::<pg_sys::Node>()
            } else {
                expr
            }
        }
    }

    /// Ensures that passed argument is ineed a valid [`pg_sys::SupportRequestSimplify`].
    /// Should only be called when input is an argument of a support function.
    #[inline]
    unsafe fn extract_simplify_request(
        input: Internal,
    ) -> Option<*mut pg_sys::SupportRequestSimplify> {
        let input: *mut pg_sys::Node = input.unwrap().unwrap() as _;
        if !pgx::is_a(input, pg_sys::NodeTag_T_SupportRequestSimplify) {
            return None;
        }

        let req: *mut pg_sys::SupportRequestSimplify = input.cast();
        let root = (*req).root;
        if root.is_null() {
            return None;
        }

        // This prevents recursion of this optimization when the subselect is planned
        if (*root).query_level > 1 {
            return None;
        }

        Some(req)
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {

    use pgx::*;

    fn setup() {
        Spi::run(
            r#"
            CREATE TABLE gfs_test_table(t TIMESTAMPTZ, v DOUBLE PRECISION, tm ps_trace.tag_map);
            INSERT INTO gfs_test_table (t, tm, v) VALUES
                ('2000-01-02T15:00:00+00:00', '{"a": 0}',  0),
                ('2000-01-02T15:05:00+00:00', '{"a": 12}', 12),
                ('2000-01-02T15:10:00+00:00', '{"a": 24}', 24),
                ('2000-01-02T15:15:00+00:00', '{"a": 36}', 36),
                ('2000-01-02T15:20:00+00:00', '{"a": 48}', 48),
                ('2000-01-02T15:25:00+00:00', '{"a": 60}', 60),
                ('2000-01-02T15:30:00+00:00', '{"a": 0}',  0),
                ('2000-01-02T15:35:00+00:00', '{"a": 12}', 12),
                ('2000-01-02T15:40:00+00:00', '{"a": 24}', 24),
                ('2000-01-02T15:45:00+00:00', '{"a": 36}', 36),
                ('2000-01-02T15:50:00+00:00', '{"a": 48}', 48);
            ANALYZE;
        "#,
        );
    }

    #[pg_test]
    fn test_unsupported_function_output_as_expected() {
        setup();
        Spi::run(
            r#"
                CREATE OR REPLACE FUNCTION arbitrary_function(key text, value text)
                RETURNS text
                AS $func$
                    SELECT key || value
                $func$
                LANGUAGE SQL STABLE PARALLEL SAFE;
            "#,
        );
        let result = Spi::get_one::<Json>(
            r#"
                EXPLAIN (COSTS OFF, FORMAT JSON)
                    SELECT * FROM gfs_test_table WHERE arbitrary_function('const','value') = 'constvalue';
            "#,
        )
        .expect("SQL query failed");

        let top_level_plan = result.0[0]["Plan"].clone();
        let sub_plans = top_level_plan.get("Plans");
        assert_eq!(top_level_plan["Node Type"], "Seq Scan");
        assert!(
            sub_plans.is_none(),
            "did not expect to find a plan with multiple sub-plans"
        );
    }

    #[pg_test]
    fn test_supported_function_output_as_expected() {
        setup();
        Spi::run(
            r#"
                CREATE OR REPLACE FUNCTION arbitrary_function(key text, value text)
                RETURNS text
                AS $func$
                    SELECT key || value
                $func$
                LANGUAGE SQL STABLE PARALLEL SAFE
                SUPPORT rewrite_fn_call_to_subquery;
            "#,
        );
        let result = Spi::get_one::<Json>(
            r#"
                EXPLAIN (COSTS OFF, FORMAT JSON)
                    SELECT * FROM gfs_test_table WHERE arbitrary_function('const','value') = 'constvalue';
            "#,
        )
            .expect("SQL query failed");

        let top_level_plan = result.0[0]["Plan"].clone();
        let sub_plans = top_level_plan.get("Plans");
        assert_eq!(top_level_plan["Node Type"], "Result");
        assert!(
            sub_plans.is_some(),
            "expected a plan with multiple sub-plans"
        );
        assert!(
            sub_plans
                .unwrap()
                .as_array()
                .unwrap()
                .as_slice()
                .into_iter()
                .any(|plan| {
                    plan["Node Type"] == "Result"
                        && plan["Parent Relationship"] == "InitPlan"
                        && plan["Subplan Name"] == "InitPlan 1 (returns $0)"
                }),
            "didn't find an InitPlan subplan among subplans."
        );
    }

    #[pg_test]
    fn test_supported_tag_map_function_output_as_expected() {
        setup();

        let init_plan_result = Spi::get_one::<Json>(
            r#"
                EXPLAIN (COSTS OFF, FORMAT JSON)
                    SELECT * FROM gfs_test_table 
                    WHERE tag_v_eq(ps_trace.tag_map_denormalize(tm)->'a', 0::text::jsonb);
            "#,
        )
        .expect("SQL query failed");

        let top_level_plan = init_plan_result.0[0]["Plan"].clone();
        let sub_plans = top_level_plan.get("Plans");
        assert_eq!(top_level_plan["Node Type"], "Seq Scan");
        assert_eq!(top_level_plan["Filter"], "(tm @> $0)");
        assert!(
            sub_plans.is_some(),
            "expected a plan with multiple sub-plans"
        );
        assert!(
            sub_plans
                .unwrap()
                .as_array()
                .unwrap()
                .as_slice()
                .into_iter()
                .any(|plan| {
                    plan["Node Type"] == "Result"
                        && plan["Parent Relationship"] == "InitPlan"
                        && plan["Subplan Name"] == "InitPlan 1 (returns $0)"
                }),
            "didn't find an InitPlan subplan among subplans."
        );

        let no_init_plan_result = Spi::get_one::<Json>(
            r#"
                EXPLAIN (COSTS OFF, FORMAT JSON)
                    SELECT * FROM gfs_test_table 
                    WHERE tag_v_eq(ps_trace.tag_map_denormalize(tm)->'a', v::text::jsonb);
            "#,
        )
        .expect("SQL query failed");

        assert_eq!(
            no_init_plan_result.0[0]["Plan"]["Filter"],
            "(tm @> _ps_trace.tag_v_eq_rewrite_helper('a'::text, ((v)::text)::jsonb))"
        );
    }
}
