\unset ECHO
\set QUIET 1
\i '/testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(1);

SELECT is(1, 1, '1 = 1');

SELECT * FROM finish();