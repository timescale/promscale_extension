use pgx::*;

#[pg_schema]
mod _prom_ext {
    use num_cpus::get;
    use pgx::*;

    #[pg_extern(immutable, parallel_safe, create_or_replace)]
    pub fn num_cpus() -> i32 {
        get() as i32
    }
}
