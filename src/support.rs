use crate::palloc::ToInternal;
use pgx::*;
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
#[search_path(@extschema@)]
pub unsafe fn make_call_subquery_support(input: Internal) -> Internal {
    let input: *mut pg_sys::Node = input.unwrap().unwrap() as _;
    if !pgx::is_a(input, pg_sys::NodeTag_T_SupportRequestSimplify) {
        return ptr::null_mut::<pg_sys::Node>().internal();
    }

    let req: *mut pg_sys::SupportRequestSimplify = input.cast();

    let root = (*req).root;

    if root.is_null() {
        return (ptr::null_mut::<pg_sys::Node>()).internal();
    }

    // This prevents recursion of this optimization when the subselect is planned
    if (*root).query_level > 1 {
        return ptr::null_mut::<pg_sys::Node>().internal();
    }

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
    query.jointree = PgBox::<pg_sys::FromExpr>::alloc_node(pg_sys::NodeTag_T_FromExpr).into_pg();
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

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {

    use pgx::*;
    use serde_json::Value;

    fn setup() {
        Spi::run(
            r#"
            CREATE TABLE gfs_test_table(t TIMESTAMPTZ, v DOUBLE PRECISION);
            INSERT INTO gfs_test_table (t, v) VALUES
                ('2000-01-02T15:00:00+00:00',0),
                ('2000-01-02T15:05:00+00:00',12),
                ('2000-01-02T15:10:00+00:00',24),
                ('2000-01-02T15:15:00+00:00',36),
                ('2000-01-02T15:20:00+00:00',48),
                ('2000-01-02T15:25:00+00:00',60),
                ('2000-01-02T15:30:00+00:00',0),
                ('2000-01-02T15:35:00+00:00',12),
                ('2000-01-02T15:40:00+00:00',24),
                ('2000-01-02T15:45:00+00:00',36),
                ('2000-01-02T15:50:00+00:00',48);
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

        assert_eq!(
            result.0,
            serde_json::from_str::<Value>(
                // Note: This output can be obtained directly from postgres
                r#"
                    [{
                        "Plan": {
                            "Alias": "gfs_test_table",
                            "Async Capable": false,
                            "Node Type": "Seq Scan",
                            "Parallel Aware": false,
                            "Relation Name": "gfs_test_table"
                        }
                    }]
                "#
            )
            .unwrap()
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
                SUPPORT make_call_subquery_support;
            "#,
        );
        let result = Spi::get_one::<Json>(
            r#"
                EXPLAIN (COSTS OFF, FORMAT JSON)
                    SELECT * FROM gfs_test_table WHERE arbitrary_function('const','value') = 'constvalue';
            "#,
        )
            .expect("SQL query failed");

        assert_eq!(
            result.0,
            serde_json::from_str::<Value>(
                // Note: This output can be obtained directly from postgres
                r#"
                    [
                      {
                        "Plan": {
                          "Node Type": "Result",
                          "Parallel Aware": false,
                          "Async Capable": false,
                          "One-Time Filter": "($0 = 'constvalue'::text)",
                          "Plans": [
                            {
                              "Node Type": "Result",
                              "Parent Relationship": "InitPlan",
                              "Subplan Name": "InitPlan 1 (returns $0)",
                              "Parallel Aware": false,
                              "Async Capable": false
                            },
                            {
                              "Node Type": "Seq Scan",
                              "Parent Relationship": "Outer",
                              "Parallel Aware": false,
                              "Async Capable": false,
                              "Relation Name": "gfs_test_table",
                              "Alias": "gfs_test_table"
                            }
                          ]
                        }
                      }
                    ]
                "#
            )
            .unwrap()
        );
    }
}
