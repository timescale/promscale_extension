use pg_sys::*;
use pgx::FromDatum;
use pgx::*;
use pgx::utils::sql_entity_graph::metadata::SqlTranslatable;
use crate::utils::sql_entity_graph::metadata::{ArgumentError, Returns, ReturnsError, SqlMapping};

// Trick DDL generator into recognizing our implementation of a built-in type.
extension_sql!(
    "",
    name = "iterable_jsonb_pseudotype",
    creates = [Type(Jsonb)],
);

/// A custom wrapper for a JSONB `Datum`.
/// In contrast with [`pgx::JsonB`] that parses the entire underlying JSON
/// this type focuses on providing access to its contents via [`Iterator`].
///
/// Handles ownership if the underlying `Datum` is copied during de-TOASTing.
/// Otherwise data is likely to be bound to the current memory context, hence
/// the `'a` lifetime.
pub struct Jsonb<'a> {
    pg_jsonb: *mut pg_sys::Jsonb,
    needs_drop: bool,
    _marker: std::marker::PhantomData<&'a pg_sys::Jsonb>,
}

impl<'a> Jsonb<'a> {
    /// Traverses the entire JSON object recursively, emitting [`Token`] objects.
    pub fn tokens(&'a self) -> TokenIterator<'a> {
        let pg_jsonb_iter =
            unsafe { JsonbIteratorInit(&mut (*self.pg_jsonb).root as *mut JsonbContainer) };
        TokenIterator {
            pg_jsonb_iter,
            raw_scalar: false,
            _marker: std::marker::PhantomData,
        }
    }
}

unsafe impl<'a> SqlTranslatable for Jsonb<'a> {
    fn argument_sql() -> std::result::Result<SqlMapping, ArgumentError> {
        Ok(SqlMapping::literal("jsonb"))
    }

    fn return_sql() -> std::result::Result<Returns, ReturnsError> {
        Ok(Returns::One(SqlMapping::literal("jsonb")))
    }
}

impl<'a> FromDatum for Jsonb<'a> {
    unsafe fn from_datum(datum: Datum, is_null: bool, _: Oid) -> Option<Jsonb<'a>> {
        if is_null {
            None
        } else if datum.is_null() {
            panic!("a jsonb Datum was flagged as non-null but the datum is zero")
        } else {
            let varlena = datum.cast_mut_ptr::<pg_sys::varlena>();
            let detoasted = pg_detoast_datum(varlena);

            Some(Jsonb {
                pg_jsonb: detoasted as *mut pg_sys::Jsonb,
                // free the detoasted datum if it turned out to be a copy
                needs_drop: detoasted != varlena,
                _marker: std::marker::PhantomData,
            })
        }
    }

    unsafe fn from_datum_in_memory_context(
        mut memory_context: PgMemoryContexts,
        datum: Datum,
        is_null: bool,
        _typoid: u32,
    ) -> Option<Jsonb<'a>> {
        if is_null {
            None
        } else if datum.is_null() {
            panic!("a jsonb Datum was flagged as non-null but the datum is zero")
        } else {
            memory_context.switch_to(|_| {
                let detoasted = pg_detoast_datum_copy(datum.cast_mut_ptr());
                Some(Jsonb {
                    pg_jsonb: detoasted as *mut pg_sys::Jsonb,
                    needs_drop: true,
                    _marker: std::marker::PhantomData,
                })
            })
        }
    }
}

impl Drop for Jsonb<'_> {
    fn drop(&mut self) {
        if self.needs_drop {
            unsafe {
                pfree(self.pg_jsonb as void_mut_ptr);
            }
        }
    }
}

#[derive(Debug)]
pub enum Token<'a> {
    BeginArray,
    EndArray,
    BeginObject,
    EndObject,
    /// Reresents a key in a JSON object.
    /// Always followed a non-key [`Token`],
    /// representing an associated value.
    Key(&'a str),
    // Scalar values used as array elements and object values
    Null,
    Bool(bool),
    String(&'a str),
    Numeric(JsonbNormalizedNumeric), // Normalized with numeric_normalize
}

pub struct TokenIterator<'a> {
    pg_jsonb_iter: *mut JsonbIterator,
    raw_scalar: bool,
    _marker: std::marker::PhantomData<Jsonb<'a>>,
}

impl<'a> Iterator for TokenIterator<'a> {
    type Item = Token<'a>;

    #[allow(non_upper_case_globals)]
    fn next(&mut self) -> Option<Self::Item> {
        let mut jsonb_val = JsonbValue::default();
        let r: JsonbIteratorToken = unsafe {
            JsonbIteratorNext(
                &mut self.pg_jsonb_iter as *mut *mut JsonbIterator,
                &mut jsonb_val as *mut JsonbValue,
                false,
            )
        };
        match r {
            JsonbIteratorToken_WJB_DONE => None,
            JsonbIteratorToken_WJB_BEGIN_ARRAY => {
                if unsafe { jsonb_val.val.array.as_ref().rawScalar } {
                    self.raw_scalar = true;
                    self.next()
                } else {
                    Some(Token::BeginArray)
                }
            }
            JsonbIteratorToken_WJB_END_ARRAY => {
                if self.raw_scalar {
                    self.next()
                } else {
                    Some(Token::EndArray)
                }
            }
            JsonbIteratorToken_WJB_BEGIN_OBJECT => Some(Token::BeginObject),
            JsonbIteratorToken_WJB_END_OBJECT => Some(Token::EndObject),
            JsonbIteratorToken_WJB_KEY => {
                match TokenIterator::extract_value_token(&mut jsonb_val) {
                    Token::String(str) => Some(Token::Key(str)),
                    _ => {
                        elog(PgLogLevel::ERROR, "Unexpected token while expecting a key");
                        None
                    }
                }
            }
            JsonbIteratorToken_WJB_VALUE | JsonbIteratorToken_WJB_ELEM => {
                Some(TokenIterator::extract_value_token(&mut jsonb_val))
            }
            _ => {
                elog(
                    PgLogLevel::ERROR,
                    format!("invalid JsonbIteratorNext rc: {}", r).as_str(),
                );
                None
            }
        }
    }
}

impl<'a> TokenIterator<'a> {
    /// It's only safe to call this function when the caller has
    /// validated the [`JsonbValue`]'s type is [`jbvType_jbvString`].
    #[inline]
    unsafe fn extract_string_value(jsonb_val: &mut JsonbValue) -> &'a str {
        let str_val = jsonb_val.val.string.as_ref();
        std::str::from_utf8_unchecked(std::slice::from_raw_parts::<'a, _>(
            str_val.val as *mut u8,
            str_val.len as usize,
        ))
    }

    #[inline]
    #[allow(non_upper_case_globals)]
    fn extract_value_token(jsonb_val: &mut JsonbValue) -> Token<'a> {
        match jsonb_val.type_ as jbvType {
            jbvType_jbvNull => Token::Null,
            jbvType_jbvString => {
                Token::String(unsafe { TokenIterator::extract_string_value(jsonb_val) })
            }
            jbvType_jbvNumeric => {
                Token::Numeric(unsafe { JsonbNormalizedNumeric::extract_numeric_value(jsonb_val) })
            }
            jbvType_jbvBool => Token::Bool(unsafe { *jsonb_val.val.boolean.as_ref() }),
            t => {
                panic!("invalid scalar jsonb type: {}", t)
            }
        }
    }
}

/// Consumes iterator completely to free allocated memory
impl Drop for TokenIterator<'_> {
    #[inline]
    fn drop(&mut self) {
        if self.next().is_some() {
            let _ = self.last();
        }
    }
}

/// The intent of this is to represent values that are equal if
/// and only if the input numeric values compare equal.
///
/// An additional wrapper is introduced to avoid allocating [`String`]
/// unless absolutely required.
pub struct JsonbNormalizedNumeric {
    numeric_str: *mut std::os::raw::c_char,
}

impl JsonbNormalizedNumeric {
    /// It's only safe to call this function when the caller has
    /// validated the [`JsonbValue`]'s type is [`jbvType_jbvNumeric`].
    #[inline]
    unsafe fn extract_numeric_value(jsonb_val: &mut JsonbValue) -> JsonbNormalizedNumeric {
        let numeric_str = numeric_normalize(*jsonb_val.val.numeric.as_ref());
        JsonbNormalizedNumeric { numeric_str }
    }

    #[inline]
    pub fn to_str(&self) -> &str {
        unsafe { std::ffi::CStr::from_ptr(self.numeric_str) }
            .to_str()
            .unwrap()
    }

    #[allow(dead_code)]
    pub fn to_pgx_numeric(&self) -> pgx::Numeric {
        pgx::Numeric(self.to_str().to_string())
    }
}

impl Drop for JsonbNormalizedNumeric {
    fn drop(&mut self) {
        unsafe { pfree(self.numeric_str as void_mut_ptr) }
    }
}

impl core::fmt::Debug for JsonbNormalizedNumeric {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("JsonbNormalizedNumeric")
            .field("numeric", &self.to_str().to_string())
            .finish()
    }
}
