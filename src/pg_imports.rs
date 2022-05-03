//! This module contains functions that are either not imported
//! by our version of pgx or diverge between versions of
//! PostrgeSQL and thus require conditional compilation.

use pgx::*;

#[derive(Default, Debug)]
pub struct FuncDetail {
    pub func_oid: pg_sys::Oid,
    pub ret_type_oid: pg_sys::Oid,
    pub retset: bool,
    pub nvargs: ::std::os::raw::c_int,
    pub vatype: pg_sys::Oid,
    pub code: pg_sys::FuncDetailCode,
}

#[cfg(not(any(feature = "pg12", feature = "pg13")))]
#[inline]
pub fn func_get_detail<'a, I>(func_path: I, types: &mut [pg_sys::Oid]) -> FuncDetail
where
    I: IntoIterator<Item = &'a str>,
{
    let arg_cnt = types.len() as i32;
    let fully_qualified_name = crate::build_pg_list_of_cstrings(func_path);
    let mut true_typeoids: *mut pg_sys::Oid = std::ptr::null_mut();
    let mut fd_struct: FuncDetail = Default::default();
    fd_struct.code = unsafe {
        pg_sys::func_get_detail(
            fully_qualified_name.as_ptr(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            arg_cnt,
            types.as_mut_ptr(),
            false,
            false,
            false,
            &mut fd_struct.func_oid,
            &mut fd_struct.ret_type_oid,
            &mut fd_struct.retset,
            &mut fd_struct.nvargs,
            &mut fd_struct.vatype,
            &mut true_typeoids,
            std::ptr::null_mut(),
        )
    };
    fd_struct
}

// When compiling against PG12 and PG13 the underlying function takes fewer arguments
#[cfg(any(feature = "pg12", feature = "pg13"))]
#[inline]
pub fn func_get_detail<'a, I>(func_path: I, types: &mut [pg_sys::Oid]) -> FuncDetail
where
    I: IntoIterator<Item = &'a str>,
{
    let arg_cnt = types.len() as i32;
    let fully_qualified_name = crate::build_pg_list_of_cstrings(func_path);
    let mut true_typeoids: *mut pg_sys::Oid = std::ptr::null_mut();
    let mut fd_struct: FuncDetail = Default::default();
    fd_struct.code = unsafe {
        pg_sys::func_get_detail(
            fully_qualified_name.as_ptr(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            arg_cnt,
            types.as_mut_ptr(),
            false,
            false,
            &mut fd_struct.func_oid,
            &mut fd_struct.ret_type_oid,
            &mut fd_struct.retset,
            &mut fd_struct.nvargs,
            &mut fd_struct.vatype,
            &mut true_typeoids,
            std::ptr::null_mut(),
        )
    };
    fd_struct
}

#[cfg(not(any(feature = "pg12", feature = "pg13")))]
#[inline]
pub fn set_sa_hashfuncid(
    scalar_array_op: &mut pg_sys::ScalarArrayOpExpr,
    hash_func_oid: pg_sys::Oid,
) {
    scalar_array_op.hashfuncid = hash_func_oid;
}

#[cfg(any(feature = "pg12", feature = "pg13"))]
#[inline]
pub fn set_sa_hashfuncid(
    _scalar_array_op: &mut pg_sys::ScalarArrayOpExpr,
    _hash_func_oid: pg_sys::Oid,
) {
    // the field didn't exist prior to pg14
}

// pg_guard doesn't compile, so we have to do without it for now.
// TODO maybe suggest adding "parser/parse_oper.h" to PGX's pg_sys
// See https://github.com/tcdi/pgx/pull/549
extern "C" {
    pub fn LookupOperName(
        pstate: *mut pg_sys::ParseState,
        opername: *mut pg_sys::List,
        oprleft: pg_sys::Oid,
        oprright: pg_sys::Oid,
        noError: bool,
        location: ::std::os::raw::c_int,
    ) -> pg_sys::Oid;
}
