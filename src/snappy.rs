use std::io::Read;

use pgx::*;
use snap::read::FrameDecoder;

#[pg_extern]
pub fn unnest_tstz_sn(bytes: &[u8]) -> impl Iterator<Item = pg_sys::TimestampTz> + '_ {
    decompress_then(bytes, i64::from_le_bytes)
}

#[pg_extern]
pub fn unnest_i64_sn(bytes: &[u8]) -> impl Iterator<Item = i64> + '_ {
    decompress_then(bytes, i64::from_le_bytes)
}

#[pg_extern]
pub fn unnest_f64_sn(bytes: &[u8]) -> impl Iterator<Item = f64> + '_ {
    decompress_then(bytes, f64::from_le_bytes)
}

fn decompress_then<'a, T>(
    bytes: &'a [u8],
    mut f: impl FnMut([u8; 8]) -> T + 'a,
) -> impl Iterator<Item = T> + 'a {
    let mut decoder = FrameDecoder::new(bytes);

    std::iter::from_fn(move || {
        let mut num = [0; 8];
        let r = decoder.read_exact(&mut num);

        // TODO real error handling
        if r.is_err() {
            return None;
        }
        Some(f(num))
    })
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgx::*;

    // #[pg_test]
    // fn test_snappy_decompresses_bigints() {
    //     let result = Spi::get_one::<Vec<u8>>(
    //         r#"
    //             SELECT unnest_i64_sn('\xff060000734e6150705900240000bdb3906d2800ff0d01040200090100030907400004000000000000000500000000000000'::bytea);
    //         "#,
    //     )
    //         .expect("SQL query failed");
    //
    //     assert_eq!(result, vec!(1, 2, 3, 4, 5));
    // }
}
