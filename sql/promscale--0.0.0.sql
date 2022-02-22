CREATE TABLE _ps_catalog.migration(
  name TEXT NOT NULL PRIMARY KEY
, applied_at_version TEXT
, applied_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);
