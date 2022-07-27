\unset ECHO
\set QUIET 1
\i 'testdata/scripts/pgtap-1.2.0.sql'

SELECT * FROM plan(49);
--
-- Moved from TestSQLDropMetricChunk
--

DO $$
DECLARE
 s1_series_id BIGINT;
 s2_series_id BIGINT;
 s3_series_id BIGINT;
BEGIN
 -- Avoid randomness in chunk interval size by setting explicitly.
 PERFORM _prom_catalog.get_or_create_metric_table_name('test');
 PERFORM public.set_chunk_time_interval('prom_data.test', interval '8 hours');
 -- Set 1h epoch duration to prevent changing defaults from affecting this test's outcome.
 PERFORM _prom_catalog.set_default_value('epoch_duration', (interval '1 hour')::text);


 -- this series (s1) will be deleted along with it's label
 SELECT f.series_id 
  FROM _prom_catalog.get_or_create_series_id_for_kv_array('test', ARRAY['__name__', 'name1'], ARRAY['test', 'value1']) f
  INTO STRICT s1_series_id;
 SELECT f.series_id
  FROM _prom_catalog.get_or_create_series_id_for_kv_array('test', ARRAY['__name__', 'name1'], ARRAY['test', 'value2']) f
  INTO STRICT s2_series_id;
 SELECT f.series_id
  FROM _prom_catalog.get_or_create_series_id_for_kv_array('test', ARRAY['__name__', 'name1'], ARRAY['test', 'value3']) f
  INTO STRICT s3_series_id;

 INSERT INTO prom_data.test(time,value,series_id)
  VALUES
   -- this will be dropped immediately (notice it's one second before the midnight)
   ('2009-11-10 23:59:59.999+00',0.1,s1_series_id), 
   -- same as the above
   ('2009-11-10 23:59:59.999+00',0.1,s3_series_id),
   -- this will remain after the drop
   ('2009-11-11 00:00:00+00',    0.2,s2_series_id),
   -- this will not be dropped and is more than an hour newer
   ('2009-11-11 05:00:00+00',    0.1,s3_series_id); 

 PERFORM
    CASE current_epoch > 0::BIGINT + 1 WHEN true THEN _prom_catalog.epoch_abort(0) 
    END
  FROM _prom_catalog.ids_epoch 
  LIMIT 1;

 CALL _prom_catalog.finalize_metric_creation();
END$$;
-- Ingestion complete

-- Checking state of the ingested data prior to drop attempts
SELECT ok(count(*) = 4, 'none of the chunks are deleted') FROM prom_data.test;
SELECT ok(count(*) = 3, 'none of the series should be removed yet') FROM _prom_catalog.series;
SELECT ok(count(*) = 0, 'none of the series should be marked for deletion') FROM _prom_catalog.series WHERE delete_epoch IS NOT NULL;
SELECT ok(count(*) = 3, 'none of the labels should deleted yet') FROM _prom_catalog.label where key='name1';

-- Dropping the data
CREATE FUNCTION asserts_before_deletion(msg TEXT)
 RETURNS SETOF TEXT
 LANGUAGE plpgsql VOLATILE AS
$fnc$
BEGIN
 RETURN NEXT is(count(*), 2::BIGINT, msg || ': expired chunks are gone') FROM prom_data.test;
 RETURN NEXT is(count(*), 3::BIGINT, msg || ': none of the series should be removed yet') FROM _prom_catalog.series;
 RETURN NEXT is(count(*), 1::BIGINT, msg || ': one series should be marked for deletion') FROM _prom_catalog.series WHERE delete_epoch IS NOT NULL;
 RETURN NEXT is(count(*), 3::BIGINT, msg || ': none of the labels should deleted yet') FROM _prom_catalog.label where key='name1';
 RETURN;
END;
$fnc$;

-- The first attempt to drop the chunks.
CALL _prom_catalog.drop_metric_chunks('prom_data', 'test', E'2009-11-11 00:00:05+00');
SELECT asserts_before_deletion('after the first timestamp');
-- Attempting to drop chunks while incrementally moving `run_at` by an hour
-- reruns shouldn't change anything until the epoch advances beyond current_epoch + 4
-- 
-- And current_epoch advances every time ran_at advances for the length of an epoch
-- duration. Which we set to be 1h at the beginning of this test.
CALL _prom_catalog.drop_metric_chunks('prom_data', 'test', E'2009-11-11 00:00:05+00');
SELECT asserts_before_deletion('after iter 0');
CALL _prom_catalog.drop_metric_chunks('prom_data', 'test', E'2009-11-11 00:00:05+00', now() + '1 hours');
SELECT asserts_before_deletion('after iter 1');
CALL _prom_catalog.drop_metric_chunks('prom_data', 'test', E'2009-11-11 00:00:05+00', now() + '2 hours');
SELECT asserts_before_deletion('after iter 2');
CALL _prom_catalog.drop_metric_chunks('prom_data', 'test', E'2009-11-11 00:00:05+00', now() + '3 hours');
SELECT asserts_before_deletion('after iter 3');
CALL _prom_catalog.drop_metric_chunks('prom_data', 'test', E'2009-11-11 00:00:05+00', now() + '4 hours');
SELECT asserts_before_deletion('after iter 4');


CREATE FUNCTION asserts_after_deletion(msg TEXT)
 RETURNS SETOF TEXT
 LANGUAGE plpgsql VOLATILE AS
$fnc$
BEGIN
 RETURN NEXT is(count(*), 2::BIGINT, msg || ': expired chunks are gone') FROM prom_data.test;
 RETURN NEXT is(count(*), 2::BIGINT, msg || ': one series should be removed') FROM _prom_catalog.series;
 RETURN NEXT is(count(*), 0::BIGINT, msg || ': no series should be marked for deletion') FROM _prom_catalog.series WHERE delete_epoch IS NOT NULL;
 RETURN NEXT is(count(*), 2::BIGINT, msg || ': unused labels should deleted') FROM _prom_catalog.label where key='name1';
 RETURN;
END;
$fnc$;

-- Now current_epoch advanced far enough and it is the time to actually drop the unused series
CALL _prom_catalog.drop_metric_chunks('prom_data', 'test', E'2009-11-11 00:00:05+00', now() + '5 hours');
SELECT asserts_after_deletion('after iter 5');            
CALL _prom_catalog.drop_metric_chunks('prom_data', 'test', E'2009-11-11 00:00:05+00', now() + '6 hours');
SELECT asserts_after_deletion('after iter 6');            
CALL _prom_catalog.drop_metric_chunks('prom_data', 'test', E'2009-11-11 00:00:05+00', now() + '7 hours');
SELECT asserts_after_deletion('after iter 7');            
CALL _prom_catalog.drop_metric_chunks('prom_data', 'test', E'2009-11-11 00:00:05+00', now() + '8 hours');
SELECT asserts_after_deletion('after iter 8');            
CALL _prom_catalog.drop_metric_chunks('prom_data', 'test', E'2009-11-11 00:00:05+00', now() + '9 hours');
SELECT asserts_after_deletion('after all iterations');

SELECT throws_like(
  'SELECT
     CASE current_epoch > 0::BIGINT + 1 WHEN true THEN _prom_catalog.epoch_abort(0) 
     END
   FROM _prom_catalog.ids_epoch 
   LIMIT 1;',
   'epoch 0 to old to continue INSERT, current: %',
   'Epoch has changed after a series was dropped'
 );

-- The end
SELECT * FROM finish(true);