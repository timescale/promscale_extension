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

            let state = &*$state;
            let serialized_size = bincode::serialized_size(state)
                .unwrap_or_else(|e| pgx::error!("serialization error {}", e));
            let size = serialized_size + 2; // size of serialized data + our version flags
            let mut bytes = Vec::with_capacity(size as usize + 4);
            let varsize = [0; 4];
            bytes.extend_from_slice(&varsize);
            // type version
            bytes.push($version);
            // serialization version; 1 for bincode is currently the only option
            bytes.push(SerializationType::Default as u8);
            bincode::serialize_into(&mut bytes, state)
                .unwrap_or_else(|e| pgx::error!("serialization error {}", e));
            unsafe {
                ::pgx::set_varsize(bytes.as_mut_ptr() as *mut _, bytes.len() as i32);
            }
            bytes.leak().as_mut_ptr() as pg_sys::Datum
        }
    };
}
#[macro_export]
macro_rules! do_deserialize {
    ($bytes: ident, $t: ty) => {{
        use $crate::type_builder::SerializationType;

        let state: $t = unsafe {
            let detoasted = pg_sys::pg_detoast_datum_packed($bytes as *mut _);
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
