use std::{
    ops::{Deref, DerefMut},
    ptr::NonNull,
};

use pgx::*;

pub use pgx::Internal;

#[allow(clippy::missing_safety_doc)]
pub unsafe trait InternalAsValue {
    unsafe fn to_inner<T>(self) -> Option<Inner<T>>;
}

unsafe impl InternalAsValue for Internal {
    unsafe fn to_inner<T>(self) -> Option<Inner<T>> {
        self.unwrap().map(|p| Inner(NonNull::new(p as _).unwrap()))
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
        self.map(|p| p.0.as_ptr() as pg_sys::Datum).into()
    }
}

unsafe impl<T> ToInternal for Inner<T> {
    fn internal(self) -> Internal {
        Some(self.0.as_ptr() as pg_sys::Datum).into()
    }
}

impl<T> From<T> for Inner<T> {
    fn from(t: T) -> Self {
        unsafe { Internal::new(t).to_inner().unwrap() }
    }
}

unsafe impl<T> ToInternal for *mut T {
    fn internal(self) -> Internal {
        Internal::from(Some(self as pg_sys::Datum))
    }
}
