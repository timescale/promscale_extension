#![allow(non_camel_case_types)]

use pgx::*;

// TODO: Is this the right approach to declaring `bytea` and `TimestampTz`?
extension_sql!(
    "",
    name = "pseudo_create_types",
    creates = [Type(bytea), Type(TimestampTz)],
);

macro_rules! raw_type {
    ($name:ident, $tyid: path, $arrayid: path) => {
        impl FromDatum for $name {
            const NEEDS_TYPID: bool = false;

            unsafe fn from_datum(
                datum: pg_sys::Datum,
                is_null: bool,
                _typoid: pg_sys::Oid,
            ) -> Option<Self>
            where
                Self: Sized,
            {
                if is_null {
                    return None;
                }
                Some(Self(datum))
            }
        }

        impl IntoDatum for $name {
            fn into_datum(self) -> Option<pg_sys::Datum> {
                Some(self.0)
            }
            fn type_oid() -> pg_sys::Oid {
                $tyid
            }
            fn array_type_oid() -> pg_sys::Oid {
                $arrayid
            }
        }

        impl From<pg_sys::Datum> for $name {
            fn from(d: pg_sys::Datum) -> Self {
                Self(d)
            }
        }

        #[allow(clippy::from_over_into)]
        impl Into<pg_sys::Datum> for $name {
            fn into(self) -> pg_sys::Datum {
                self.0
            }
        }
    };
}

#[derive(Clone, Copy)]
pub struct bytea(pub pg_sys::Datum);

raw_type!(bytea, pg_sys::BYTEAOID, pg_sys::BYTEAARRAYOID);
