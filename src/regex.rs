use pgx::*;

#[pg_schema]
mod _prom_ext {
    use pgx::*;
    use regex::Regex;
    use std::cell::RefCell;
    use uluru::LRUCache;

    // On caching: Creating a new Regex instance is expensive, so we keep a
    // global cache of Regex instances in an LRU cache.
    // An alternative approach would be to create a new regex type, and provide
    // match functions between our custom regex type and TEXT (see pgpcre [1]).
    // This would work, but requires dealing with the fact that somebody might
    // decide to _store_ the compiled regex, which we don't want to support.
    // Interestingly, the Postgres' native regex engine is quite similar,
    // storing compiled regex expressions in an LRU cache of 32 elements [2].
    //
    // [1]: https://github.com/petere/pgpcre/blob/c36de3d9b84f7740f24083b2e55fc6fcb33ec849/pgpcre.c
    // [2]: https://github.com/postgres/postgres/blob/f5135d2aba87f59944bdab4f54129fc43a3f03d0/src/backend/utils/adt/regexp.c

    // On memory contexts: This cache and function do not behave nicely with
    // Postgres' memory models. Allocations are not in a MemoryContext, instead
    // they are directly on the stack, or heap. This is safe because we do not
    // ever pass these objects to Postgres.

    // Caveats: We completely ignore collation, and character sets.

    struct CompiledRegex {
        pattern: String,
        matcher: Regex,
    }

    // Note: The chosen size is the same as Postgres' internal regex cache
    const CACHE_SIZE: usize = 32;

    thread_local! {
        static CACHE: RefCell<LRUCache<CompiledRegex, CACHE_SIZE>> = RefCell::default();
    }

    /// re2_match matches `string` against `pattern` using an [RE2-like][re2]
    /// regular expression engine, returning a `BOOLEAN`.
    /// [re2]: https://github.com/google/re2
    #[pg_extern(immutable, parallel_safe, create_or_replace)]
    fn re2_match(string: &str, pattern: &str) -> bool {
        CACHE.with(|cache| {
            let mut cache = cache.borrow_mut();
            match cache.find(|i| i.pattern == pattern) {
                Some(compiled) => compiled.matcher.is_match(string),
                None => match Regex::new(pattern) {
                    Ok(matcher) => {
                        cache.insert(CompiledRegex {
                            pattern: String::from(pattern),
                            matcher: matcher.clone(),
                        });
                        matcher.is_match(string)
                    }
                    Err(e) => {
                        pgx::error!("unable to compile regular expression: {}", e)
                    }
                },
            }
        })
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgx::*;

    #[pg_test]
    fn test_trivial_regex() {
        let result =
            Spi::get_one::<bool>("SELECT re2_match('test', 'test');").expect("SQL query failed");
        assert_eq!(result, true);
        let result =
            Spi::get_one::<bool>("SELECT re2_match('test', 'unnest');").expect("SQL query failed");
        assert_eq!(result, false);
    }

    #[pg_test]
    fn test_case_insensitive_regex() {
        let result = Spi::get_one::<bool>(r#"SELECT re2_match('A123', '(?i)^a\d+');"#)
            .expect("SQL query failed");
        assert_eq!(result, true);
    }

    #[pg_test(
        error = "unable to compile regular expression: Compiled regex exceeds size limit of 10485760 bytes."
    )]
    fn test_regex_too_large() {
        Spi::get_one::<bool>(r#"SELECT re2_match('a', 'a'||repeat('.?', 10000));"#);
    }

    #[pg_test]
    fn test_regex_too_large_does_not_kill_session() {
        let _ = pg_try(|| {
            Spi::run(r#"SELECT re2_match('a', 'a'||repeat('.?', 10000));"#);
        });
        let result =
            Spi::get_one::<bool>(r#"SELECT re2_match('a', 'a');"#).expect("SQL query failed");
        assert_eq!(result, true);
    }
}
