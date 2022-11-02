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

    type BufferItem = composite_type!(COMPOSITE_TYPE_NAME);
    struct Buffer {
        mem_ctx: PgMemoryContexts,
        list: PgList<BufferItem>,
    }

    struct BufferIter<'b> {
        buffer: &'b mut Buffer,
        pos: usize,
    }

    impl<'a> Iterator for BufferIter<'a> {
        type Item = BufferItem;

        fn next(&mut self) -> Option<Self::Item> {
            // We are not deallocaing anything here because Drop does it wholesale.
            let item = self.buffer.list.get_ptr(self.pos);
            self.pos += 1;
            // SAFETY: push_rec is expected to be the only funciton appending to buffer.list
            item.map(|i| unsafe {
                PgHeapTuple::from_datum_in_memory_context(
                    PgMemoryContexts::CurrentMemoryContext,
                    i.into(),
                    false,
                    BufferItem::type_oid(),
                )
                .unwrap()
            })
        }

        fn size_hint(&self) -> (usize, Option<usize>) {
            let remaining = self.buffer.list.len() - self.pos;
            (remaining, Some(remaining))
        }
    }

    impl<'a> Drop for BufferIter<'a> {
        fn drop(&mut self) {
            // Drop on the list calls list_free(). For it to work without segfaults we first 
            // need to replace the list (triggering the Drop) and only then call mem_ctx.reset()
            self.buffer.list = PgMemoryContexts::CacheMemoryContext.switch_to(|_| PgList::new());
            self.buffer.mem_ctx.reset();
            self.buffer.list = self.buffer.mem_ctx.switch_to(|_| PgList::new());
        }
    }

    fn init_buffer() -> &'static Mutex<Buffer> {
        static mut SINGLETON: MaybeUninit<Mutex<Buffer>> = MaybeUninit::uninit();
        static ONCE: Once = Once::new();

        unsafe {
            ONCE.call_once(|| {
                let mut mem_ctx = PgMemoryContexts::CacheMemoryContext
                    .switch_to(|_| PgMemoryContexts::new("backend_telemetry_buffer_context"));
                let list = mem_ctx.switch_to(|_| PgList::new());
                let singleton = Mutex::new(Buffer { mem_ctx, list });
                SINGLETON.write(singleton);
            });

            SINGLETON.assume_init_ref()
        }
    }

    #[pg_extern(volatile, strict, create_or_replace, requires = ["backend_telemetry_rec_decl"])]
    pub fn push_rec(
        _r: pgx::composite_type!(COMPOSITE_TYPE_NAME),
        fcinfo: pg_sys::FunctionCallInfo,
    ) -> bool {
        let buffer_mutex = init_buffer();
        let r_datum = pg_getarg_datum_raw(fcinfo, 0);
        {
            let mut q_guard = buffer_mutex.lock().unwrap();
            let prev_ctx = q_guard.mem_ctx.set_as_current();
            let detoasted = unsafe {
                pg_sys::pg_detoast_datum_copy(r_datum.cast_mut_ptr() as *mut pg_sys::varlena)
            };
            q_guard.list.push(detoasted.cast());
            prev_ctx.set_as_current();
        }
        true
    }

    #[pg_extern(volatile, strict, create_or_replace, requires = ["backend_telemetry_rec_decl"])]
    pub fn pop_recs() -> SetOfIterator<'static, pgx::composite_type!(COMPOSITE_TYPE_NAME)> {
        let buffer_mutex = init_buffer();
        let mut q_guard = buffer_mutex.lock().unwrap();
        SetOfIterator::new(
            BufferIter {
                buffer: &mut q_guard,
                pos: 0,
            }
            .collect::<Vec<_>>(),
        )
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
        let n = 1000;
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
    fn test_backend_telemetry_buffer_clean_after_pop() {
        Spi::get_one::<bool>("SELECT push_rec(ROW(now(), 1));").expect("SQL query failed");
        Spi::get_one::<bool>("SELECT 1 FROM pop_recs() x;").expect("SQL query failed");
        assert!(
            Spi::get_one::<bool>("SELECT 1 FROM pop_recs() x;").is_none(),
            "telemetry buffer must be cleared by pop_recs"
        );
    }
}
