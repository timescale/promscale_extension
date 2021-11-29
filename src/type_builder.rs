#[repr(u8)]
pub enum SerializationType {
    Default = 1,
}

#[macro_export]
macro_rules! do_serialize {
    ($state: ident) => {
        {
            $crate::do_serialize!($state, version: 1)
        }
    };
    ($state: ident, version: $version: expr) => {
        {
            use $crate::type_builder::SerializationType;
            use std::io::{Cursor, Write};
            use std::convert::TryInto;

            let state = &*$state;
            let serialized_size = bincode::serialized_size(state)
                .unwrap_or_else(|e| pgx::error!("serialization error {}", e));
            let our_size = serialized_size + 2; // size of serialized data + our version flags
            let allocated_size = our_size + 4; // size of our data + the varlena header
            let allocated_size = allocated_size.try_into()
                .unwrap_or_else(|e| pgx::error!("serialization error {}", e));
            // valena tyes have a maximum size
            if allocated_size > 0x3FFFFFFF {
                pgx::error!("size {} bytes is to large", allocated_size)
            }

            let bytes: &mut [u8] = unsafe {
                let bytes = pgx::pg_sys::palloc0(allocated_size);
                std::slice::from_raw_parts_mut(bytes.cast(), allocated_size)
            };
            let mut writer = Cursor::new(bytes);
            // varlena header space
            let varsize = [0; 4];
            writer.write_all(&varsize)
                .unwrap_or_else(|e| pgx::error!("serialization error {}", e));
            // type version
            writer.write_all(&[$version])
                .unwrap_or_else(|e| pgx::error!("serialization error {}", e));
            // serialization version; 1 for bincode is currently the only option
            writer.write_all(&[SerializationType::Default as u8])
                .unwrap_or_else(|e| pgx::error!("serialization error {}", e));
            bincode::serialize_into(&mut writer, state)
                .unwrap_or_else(|e| pgx::error!("serialization error {}", e));
            unsafe {
                let len = writer.position().try_into().expect("serialized size too large");
                ::pgx::set_varsize(writer.get_mut().as_mut_ptr() as *mut _, len);
            }
            bytea::from(writer.into_inner().as_mut_ptr() as pg_sys::Datum)
        }
    };
}
#[macro_export]
macro_rules! do_deserialize {
    ($bytes: ident, $t: ty) => {{
        use $crate::type_builder::SerializationType;

        let state: $t = unsafe {
            let input: bytea = $bytes;
            let input: pgx::pg_sys::Datum = input.into();
            let detoasted = pg_sys::pg_detoast_datum_packed(input as *mut _);
            let len = pgx::varsize_any_exhdr(detoasted);
            let data = pgx::vardata_any(detoasted);
            let bytes = std::slice::from_raw_parts(data as *mut u8, len);
            if bytes.len() < 1 {
                pgx::error!("deserialization error, no bytes")
            }
            if bytes[0] != 1 {
                pgx::error!(
                    "deserialization error, invalid serialization version {}",
                    bytes[0]
                )
            }
            if bytes[1] != SerializationType::Default as u8 {
                pgx::error!(
                    "deserialization error, invalid serialization type {}",
                    bytes[1]
                )
            }
            bincode::deserialize(&bytes[2..])
                .unwrap_or_else(|e| pgx::error!("deserialization error {}", e))
        };
        state.into()
    }};
}
