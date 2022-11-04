//! Provides a backend-local "escape hatch" buffer for backend metrics
//! (and, in the future, logs) data. Even when an exception happens,
//! the buffer retains its contents so it may be used inside
//! an exception handler.
use pgx::*;

#[pg_schema]
mod _prom_ext {
    use pgx::{prelude::*, *};
    use std::{
        mem::MaybeUninit,
        sync::{Mutex, Once},
    };

    // Using an SQL-defined composite type allows future modifications
    // to be carried out in an incremental migration via ALTER TYPE,
    // without touching Rust code.
    extension_sql!(
        r#"
        CREATE TYPE _prom_ext.backend_telemetry_rec AS (
            time timestamp with time zone,
            value BIGINT,
            tags text[]
        );
        "#,
        name = "backend_telemetry_rec_decl"
    );

    const COMPOSITE_TYPE_NAME: &str = "_prom_ext.backend_telemetry_rec";
    const BUFFER_SIZE: usize = 10000;

    type BufferItem = composite_type!(COMPOSITE_TYPE_NAME);

    /// Holds a PG memory context and a ring buffer of pointer- [`Datum`]
    /// representing [`BufferItem`] inside the memory context.
    ///
    /// The ring buffer can hold up to [`BUFFER_SIZE`] items.
    ///
    /// The memory context is created as a child of
    /// [`PgMemoryContexts::CacheMemoryContext`]
    struct Buffer {
        mem_ctx: PgMemoryContexts,
        inner_buffer: PgBox<[Datum; BUFFER_SIZE], AllocatedByRust>,
        next_idx: usize,
    }

    /// A helper, for iterating over the [`Buffer`].
    /// Clears the buffer when dropped.
    struct BufferIter<'b> {
        buffer: &'b mut Buffer,
        pos: usize,
    }

    impl Buffer {
        fn new() -> Self {
            let mem_ctx = PgMemoryContexts::CacheMemoryContext
                .switch_to(|_| PgMemoryContexts::new("backend_telemetry_buffer_context"));
            let inner_buffer = PgBox::<[Datum; BUFFER_SIZE], AllocatedByRust>::alloc0_in_context(
                PgMemoryContexts::CacheMemoryContext,
            );
            Self {
                mem_ctx,
                inner_buffer,
                next_idx: 0,
            }
        }

        /// Copies [`BufferItem`] into the memory context associated
        /// with the [`Buffer`]. Frees an older item if it needs
        /// to be overwritten due to ring buffer overflow.
        fn append(&mut self, item: BufferItem) -> bool {
            let copied_opt = self.mem_ctx.switch_to(|_| item.into_composite_datum());
            let fully_initialized = self.next_idx >= BUFFER_SIZE;

            self.inner_buffer
                .get_mut(self.next_idx % BUFFER_SIZE)
                .and_then(|place| {
                    copied_opt.map(|copied| {
                        if fully_initialized {
                            unsafe { pg_sys::pfree(place.cast_mut_ptr()) }
                        }
                        *place = copied;
                    })
                })
                .map(|_| self.next_idx += 1)
                .is_some()
        }

        /// Empties the buffer and frees memory occupied by contained items.
        fn reset(&mut self) {
            self.next_idx = 0;
            self.mem_ctx.reset();
        }

        /// Creates an iterator, traversing all initialized items
        /// in the buffer. Calls `reset()` when dropped.
        fn consume_as_iter(&mut self) -> BufferIter {
            BufferIter {
                buffer: self,
                pos: 0,
            }
        }
    }

    impl<'a> Iterator for BufferIter<'a> {
        type Item = BufferItem;

        fn next(&mut self) -> Option<Self::Item> {
            // We are not deallocaing anything here because Drop does it wholesale.
            let cur_pos = self.pos;
            self.pos += 1;
            self.buffer
                .inner_buffer
                .get(cur_pos)
                // guard against accessing uninitialized parts of the buffer
                .filter(|_| cur_pos < self.buffer.next_idx)
                // SAFETY:
                // - append is expected to be the only funciton writing into the buffer,
                //   therefore all elements are BufferItem
                // - the if above ensures we don't access unintialized parts of the buffer
                .and_then(|datum| unsafe {
                    // mem_ctx will be reset when the iterator drops,
                    // therefore we have to copy the data into another context
                    BufferItem::from_datum_in_memory_context(
                        PgMemoryContexts::CurrentMemoryContext,
                        *datum,
                        false,
                        BufferItem::type_oid(),
                    )
                })
        }

        fn size_hint(&self) -> (usize, Option<usize>) {
            let remaining = Ord::min(BUFFER_SIZE, self.buffer.next_idx) - self.pos;
            (remaining, Some(BUFFER_SIZE))
        }
    }

    impl<'a> Drop for BufferIter<'a> {
        fn drop(&mut self) {
            self.buffer.reset();
        }
    }

    /// Returns a [`Buffer`] for the current backend, guarded
    /// by a [`Mutex`]. Initializes the buffer when called
    /// for the first time within a backend.
    fn backend_local_buffer() -> &'static Mutex<Buffer> {
        static mut SINGLETON: MaybeUninit<Mutex<Buffer>> = MaybeUninit::uninit();
        static ONCE: Once = Once::new();

        unsafe {
            ONCE.call_once(|| {
                let singleton = Mutex::new(Buffer::new());
                SINGLETON.write(singleton);
            });

            SINGLETON.assume_init_ref()
        }
    }

    /// Returns the size of backend-local ring-buffer the extension was compiled with.
    #[pg_extern(strict, create_or_replace)]
    pub fn backend_telemetry_buffer_size() -> i32 {
        use std::convert::TryInto;
        BUFFER_SIZE.try_into().unwrap()
    }

    /// Adds a `backend_telemetry_rec` record to a backend-local ring buffer.
    #[pg_extern(volatile, strict, create_or_replace, requires = ["backend_telemetry_rec_decl"])]
    // Can't use [`BufferItem`] type directly due to DDL generator quirk.
    pub fn push_rec(r: pgx::composite_type!(COMPOSITE_TYPE_NAME)) -> bool {
        let buffer_mutex = backend_local_buffer();
        let mut buffer_guard = buffer_mutex.lock().unwrap();
        buffer_guard.append(r)
    }

    /// Returns all `backend_telemetry_rec` records currently present inside a backend-local
    /// ring buffer. Clears the buffer.
    #[pg_extern(volatile, strict, create_or_replace, requires = ["backend_telemetry_rec_decl"])]
    // Can't use [`BufferItem`] type directly due to DDL generator quirk.
    pub fn pop_recs() -> SetOfIterator<'static, pgx::composite_type!(COMPOSITE_TYPE_NAME)> {
        let buffer_mutex = backend_local_buffer();
        let mut buffer_guard = buffer_mutex.lock().unwrap();
        SetOfIterator::new(buffer_guard.consume_as_iter().collect::<Vec<_>>())
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgx::*;

    #[pg_test]
    fn test_backend_telemetry_buffer_trivial_roundtrip() {
        let push_res = Spi::get_one::<bool>("SELECT push_rec(ROW(now(), 1, ARRAY['foo']));")
            .expect("SQL query failed");
        assert_eq!(push_res, true);
        let pop_res =
            Spi::get_one::<bool>("SELECT (x).time <= now() AND (x).value = 1 AND (x).tags = ARRAY['foo'] FROM pop_recs() x;")
            .expect("SQL query failed");
        assert_eq!(pop_res, true);
    }

    #[pg_test]
    fn test_backend_telemetry_buffer_multiple_roundtrip() {
        Spi::get_one::<bool>("SELECT push_rec(ROW(now(), 1, ARRAY['1']));")
            .expect("SQL query failed");
        Spi::get_one::<bool>("SELECT push_rec(ROW(now(), 2, ARRAY['2']));")
            .expect("SQL query failed");
        let pop_res = Spi::get_one::<i32>("SELECT SUM((x).value)::INT FROM pop_recs() x;")
            .expect("SQL query failed");
        assert_eq!(pop_res, 3);
    }

    #[pg_test]
    fn test_backend_telemetry_buffer_big_roundtrip() {
        let n = Spi::get_one::<i32>("SELECT backend_telemetry_buffer_size();")
            .expect("SQL query failed")
            - 1;
        for _ in 0..n {
            Spi::get_one::<bool>("SELECT push_rec(ROW(now(), 1, ARRAY[]::text[]));")
                .expect("SQL query failed");
        }
        let pop_res = Spi::get_one::<i32>(
            r#"
            SELECT SUM(CASE WHEN (x).time > now() THEN 0 ELSE (x).value END)::INT
            FROM pop_recs() x;
            "#,
        )
        .expect("SQL query failed");
        assert_eq!(pop_res, n);
    }

    #[pg_test]
    fn test_backend_telemetry_buffer_overflow() {
        let n = Spi::get_one::<i32>("SELECT backend_telemetry_buffer_size();")
            .expect("SQL query failed");
        let overflow = 10;
        for _ in 0..n {
            Spi::get_one::<bool>("SELECT push_rec(ROW(now(), 1, ARRAY['']));")
                .expect("SQL query failed");
        }
        for _ in 0..overflow {
            Spi::get_one::<bool>("SELECT push_rec(ROW(now(), 2, ARRAY['']));")
                .expect("SQL query failed");
        }
        let pop_res = Spi::get_one::<i32>(
            r#"
            SELECT SUM((x).value)::INT
            FROM pop_recs() x;
            "#,
        )
        .expect("SQL query failed");
        assert_eq!(pop_res, n - overflow + 2 * overflow);
    }

    #[pg_test]
    fn test_backend_telemetry_buffer_clean_after_pop() {
        Spi::get_one::<bool>("SELECT push_rec(ROW(now(), 1, ARRAY['']));")
            .expect("SQL query failed");
        Spi::get_one::<bool>("SELECT 1 FROM pop_recs() x;").expect("SQL query failed");
        assert!(
            Spi::get_one::<bool>("SELECT 1 FROM pop_recs() x;").is_none(),
            "telemetry buffer must be cleared by pop_recs"
        );
    }
}
