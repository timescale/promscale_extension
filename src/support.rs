use crate::palloc::ToInternal;
use pgx::*;
use std::ptr;

// FIXME: This rough translation from C to Rust is _untested_ and probably broken

/// This [support function] optimizes calls to the supported function if it's
/// called with constant-like arguments. Such calls are transformed into a
/// subquery of the function call. This allows the planner to make this call an
/// InitPlan which is evaluated once per query instead of multiple times
/// (e.g. on every tuple when the function is used in a WHERE clause).
///
/// An example of such a call is:
///
/// ```sql
/// NOT(labels && ('namespace' !== 'dev'))
/// ```
///
/// Which this support function transforms into:
///
/// ```sql
/// NOT(labels && (SELECT 'namespace' !== 'dev'))
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

    let mut te = PgBox::<pg_sys::TargetEntry>::alloc0();
    te.expr = f2 as *mut pg_sys::Expr;
    te.resno = 1;

    let mut query = PgBox::<pg_sys::Query>::alloc0();
    query.commandType = 1;
    query.jointree = PgBox::<pg_sys::FromExpr>::alloc0().into_pg();
    query.canSetTag = true;

    let mut list = PgList::<pg_sys::TargetEntry>::new();
    list.push(te.into_pg() as *mut pg_sys::TargetEntry);

    query.targetList = list.into_pg();

    let mut sublink = PgBox::<pg_sys::SubLink>::alloc0();
    sublink.subLinkType = pg_sys::SubLinkType_EXPR_SUBLINK;
    sublink.subLinkId = 0;
    sublink.subselect = query.into_pg() as *mut pg_sys::Node;

    return (sublink.into_pg() as *mut pg_sys::Node).internal();
}

pub unsafe fn arg_can_be_put_into_subquery(arg: *mut pg_sys::Node) -> bool {
    if pgx::is_a(arg, pg_sys::NodeTag_T_Const) {
        return true;
    }

    if pgx::is_a(arg, pg_sys::NodeTag_T_CoerceToDomain) {
        let domain = arg.cast::<pg_sys::CoerceToDomain>();
        return arg_can_be_put_into_subquery((*domain).arg as *mut pg_sys::Node);
    }

    return false;
}
