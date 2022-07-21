use postgres::Client;
use std::ops::{Deref, DerefMut};

use super::PostgresTestInstance;

/// A wrapper around [`postgres::Client`]
/// that can be treated as a smart-pointer.
pub struct PostgresTestConnection<'pg_inst> {
    pub client: Client,
    // a phantom to hold onto parent's lifetime
    // to prevent premature database shutdown.
    pub(crate) _parent: &'pg_inst dyn PostgresTestInstance,
}

impl<'pg> Deref for PostgresTestConnection<'pg> {
    type Target = Client;

    // &self.client can't outlive &self and therefore can't outlive 'pg
    fn deref(&self) -> &Self::Target {
        &self.client
    }
}

impl<'pg> DerefMut for PostgresTestConnection<'pg> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.client
    }
}
