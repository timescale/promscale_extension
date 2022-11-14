\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(20);

SELECT
  is(
    _prom_catalog.get_label_key_column_name_for_view(key_, true),
    format('label_%s_id', key_)::NAME,
    format('%s is a restricted keyword and sanitized. When id=true the column name is returned suffixed with `_id`', key_)
  )
FROM (
  VALUES
    ('time'),
    ('value'),
    ('series_id'),
    ('labels'),
    ('series')
  ) as reserved_keys (key_);

SELECT is(
  _prom_catalog.get_label_key_column_name_for_view('my-key', true),
  'my-key_id'::NAME,
  'when id=true the column name is returned suffixed with `_id`'
);

-- Entries in _prom_catalog.label_key are created
SELECT is(
  k.*,
  ROW(id, test.key_, test.key_, format('%s_id', test.key_))::_prom_catalog.label_key,
  format('_prom_catalog.label_key entry for %s exists', test.key_)
)
FROM (
  VALUES
    ('label_time'),
    ('label_value'),
    ('label_series_id'),
    ('label_labels'),
    ('label_series'),
    ('my-key')
  ) as test (key_)
LEFT JOIN _prom_catalog.label_key k on (k.key = test.key_);

SELECT is(
  count(*),
  6::BIGINT,
  '6 entries were created for _prom_catalog.label_key'
) FROM _prom_catalog.label_key;

SELECT is(
  _prom_catalog.get_label_key_column_name_for_view(key_, false),
  format('label_%s', key_)::NAME,
  format('%s is a restricted keyword and sanitized', key_)
)
FROM (
  VALUES
    ('time'),
    ('value'),
    ('series_id'),
    ('labels'),
    ('series')
) as reserved_keys (key_);

SELECT is(
  _prom_catalog.get_label_key_column_name_for_view('my-key', false),
  'my-key'::NAME,
  'column name is the same as key'
);

SELECT is(
  count(*),
  6::BIGINT,
  'no additional _prom_catalog.label_key are created on subsequent calls for the same keys'
) FROM _prom_catalog.label_key;

SELECT * FROM finish();
