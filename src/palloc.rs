use std::{
    ffi::CStr,
    ops::{Deref, DerefMut},
    os::raw::c_char,
    ptr::NonNull,
};

use pgx::*;

pub unsafe fn in_memory_context<T, F: FnOnce() -> T>(mctx: pg_sys::MemoryContext, f: F) -> T {
    let prev_ctx = pg_sys::CurrentMemoryContext;
    pg_sys::CurrentMemoryContext = mctx;
    let t = f();
    pg_sys::CurrentMemoryContext = prev_ctx;
    t
}

/// The type to take ownership of string values
/// that a caller is supposed to pfree.
pub struct PallocdString {
    pg_box: PgBox<c_char, AllocatedByRust>,
}

impl PallocdString {
    /// SAFETY: the pointer passed into this function must be a NULL-terminated string
    /// and conform to the requirements of [`std::ffi::CStr`]
    pub unsafe fn from_ptr(ptr: *mut c_char) -> Option<Self> {
        if ptr.is_null() {
            None
        } else {
            Some(PallocdString {
                pg_box: PgBox::<_, AllocatedByRust>::from_rust(ptr),
            })
        }
    }

    pub fn as_c_str(&self) -> &CStr {
        unsafe { CStr::from_ptr(self.pg_box.as_ptr()) }
    }
}

pub use pgx::Internal;

#[allow(clippy::missing_safety_doc)]
pub unsafe trait InternalAsValue {
    unsafe fn to_inner<T>(self) -> Option<Inner<T>>;
}

unsafe impl InternalAsValue for Internal {
    unsafe fn to_inner<T>(self) -> Option<Inner<T>> {
        self.unwrap()
            .map(|p| Inner(NonNull::new(p.cast_mut_ptr()).unwrap()))
    }
}

#[allow(clippy::missing_safety_doc)]
pub unsafe trait ToInternal {
    fn internal(self) -> Internal;
}

pub struct Inner<T>(pub NonNull<T>);

impl<T> Deref for Inner<T> {
    type Target = T;

    fn deref(&self) -> &Self::Target {
        unsafe { self.0.as_ref() }
    }
}

impl<T> DerefMut for Inner<T> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        unsafe { self.0.as_mut() }
    }
}

unsafe impl<T> ToInternal for Option<Inner<T>> {
    fn internal(self) -> Internal {
        self.map(|p| Datum::from(p.0.as_ptr())).into()
    }
}

unsafe impl<T> ToInternal for Inner<T> {
    fn internal(self) -> Internal {
        Some(Datum::from(self.0.as_ptr())).into()
    }
}

impl<T> From<T> for Inner<T> {
    fn from(t: T) -> Self {
        unsafe { Internal::new(t).to_inner().unwrap() }
    }
}

unsafe impl<T> ToInternal for *mut T {
    fn internal(self) -> Internal {
        Internal::from(Some(Datum::from(self)))
    }
}
