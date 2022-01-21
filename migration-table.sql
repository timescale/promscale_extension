-- migration-table.sql
CREATE SCHEMA IF NOT EXISTS _ps_catalog;
CREATE TABLE IF NOT EXISTS _ps_catalog.migration(
  name TEXT NOT NULL PRIMARY KEY
, applied_at_version TEXT
, applied_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);
