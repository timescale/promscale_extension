use pgx::*;

#[pg_schema]
mod _prom_ext {
    use pgx::{prelude::*, *};
    use std::{
        mem::MaybeUninit,
        sync::{Mutex, Once},
    };

    extension_sql!(
        r#"
        CREATE TYPE _prom_ext.backend_telemetry_rec AS (
            time timestamp with time zone,
            value BIGINT
        );
        "#,
        name = "backend_telemetry_rec_decl"
    );

    const COMPOSITE_TYPE_NAME: &str = "_prom_ext.backend_telemetry_rec";
    const BUFFER_SIZE: usize = 10000;

    type BufferItem = composite_type!(COMPOSITE_TYPE_NAME);
    struct Buffer {
        mem_ctx: PgMemoryContexts,
        buffer: PgBox<[Datum; BUFFER_SIZE], AllocatedByRust>,
        next_idx: usize,
    }

    impl Buffer {
        fn new() -> Self {
            let mem_ctx = PgMemoryContexts::CacheMemoryContext
                .switch_to(|_| PgMemoryContexts::new("backend_telemetry_buffer_context"));
            let buffer = PgBox::<[Datum; BUFFER_SIZE], AllocatedByRust>::alloc0_in_context(
                PgMemoryContexts::CacheMemoryContext,
            );
            Self {
                mem_ctx,
                buffer,
                next_idx: 0,
            }
        }

        fn append(&mut self, item: BufferItem) -> bool {
            let copied_opt = self.mem_ctx.switch_to(|_| item.into_composite_datum());
            let fully_initialized = self.next_idx >= BUFFER_SIZE;

            self.buffer
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

        fn reset(&mut self) {
            self.next_idx = 0;
            self.mem_ctx.reset();
        }

        fn consume_as_iter(&mut self) -> BufferIter {
            BufferIter {
                buffer: self,
                pos: 0,
            }
        }
    }

    impl Default for Buffer {
        fn default() -> Self {
            Self::new()
        }
    }

    struct BufferIter<'b> {
        buffer: &'b mut Buffer,
        pos: usize,
    }

    impl<'a> Iterator for BufferIter<'a> {
        type Item = BufferItem;

        fn next(&mut self) -> Option<Self::Item> {
            // We are not deallocaing anything here because Drop does it wholesale.
            if self.pos < self.buffer.next_idx {
                let datum_opt = self.buffer.buffer.get(self.pos);
                self.pos += 1;
                // SAFETY:
                // - append is expected to be the only funciton writing into the buffer,
                //   therefore all elements are BufferItem
                // - the if above ensures we don't access unintialized parts of the buffer
                datum_opt.and_then(|datum| unsafe {
                    // mem_ctx will be reset when the iterator drops,
                    // therefore we have to copy the data into another context
                    BufferItem::from_datum_in_memory_context(
                        PgMemoryContexts::CurrentMemoryContext,
                        *datum,
                        false,
                        BufferItem::type_oid(),
                    )
                })
            } else {
                None
            }
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

    fn init_buffer() -> &'static Mutex<Buffer> {
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

    #[pg_extern(strict, create_or_replace)]
    pub fn backend_telemetry_buffer_size() -> i32 {
        use std::convert::TryInto;
        BUFFER_SIZE.try_into().unwrap()
    }

    #[pg_extern(volatile, strict, create_or_replace, requires = ["backend_telemetry_rec_decl"])]
    pub fn push_rec(r: pgx::composite_type!(COMPOSITE_TYPE_NAME)) -> bool {
        let buffer_mutex = init_buffer();
        let mut buffer_guard = buffer_mutex.lock().unwrap();
        buffer_guard.append(r)
    }

    #[pg_extern(volatile, strict, create_or_replace, requires = ["backend_telemetry_rec_decl"])]
    pub fn pop_recs() -> SetOfIterator<'static, pgx::composite_type!(COMPOSITE_TYPE_NAME)> {
        let buffer_mutex = init_buffer();
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
        let push_res =
            Spi::get_one::<bool>("SELECT push_rec(ROW(now(), 1));").expect("SQL query failed");
        assert_eq!(push_res, true);
        let pop_res =
            Spi::get_one::<bool>("SELECT (x).time <= now() AND (x).value = 1 FROM pop_recs() x;")
                .expect("SQL query failed");
        assert_eq!(pop_res, true);
    }

    #[pg_test]
    fn test_backend_telemetry_buffer_multiple_roundtrip() {
        Spi::get_one::<bool>("SELECT push_rec(ROW(now(), 1));").expect("SQL query failed");
        Spi::get_one::<bool>("SELECT push_rec(ROW(now(), 2));").expect("SQL query failed");
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
            Spi::get_one::<bool>("SELECT push_rec(ROW(now(), 1));").expect("SQL query failed");
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
            Spi::get_one::<bool>("SELECT push_rec(ROW(now(), 1));").expect("SQL query failed");
        }
        for _ in 0..overflow {
            Spi::get_one::<bool>("SELECT push_rec(ROW(now(), 2));").expect("SQL query failed");
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
        Spi::get_one::<bool>("SELECT push_rec(ROW(now(), 1));").expect("SQL query failed");
        Spi::get_one::<bool>("SELECT 1 FROM pop_recs() x;").expect("SQL query failed");
        assert!(
            Spi::get_one::<bool>("SELECT 1 FROM pop_recs() x;").is_none(),
            "telemetry buffer must be cleared by pop_recs"
        );
    }
}
