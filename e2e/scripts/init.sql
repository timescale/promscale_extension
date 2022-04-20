\set ECHO all
\set ON_ERROR_STOP 1

CREATE EXTENSION promscale;

SELECT _prom_catalog.set_default_value('ha_lease_timeout', '200 hours');

-- todo: create metrics, exemplars, and traces
