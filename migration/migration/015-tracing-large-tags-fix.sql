ALTER TABLE _ps_trace.tag DROP CONSTRAINT tag_key_value_id_key_id_key;
CREATE UNIQUE INDEX tag_key_value_id_key_id_key ON _ps_trace.tag (key, _prom_ext.jsonb_digest(value)) INCLUDE (id, key_id);