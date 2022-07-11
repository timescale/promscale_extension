# Promscale Extension

From Promscale version 0.11.0, this [Postgres extension](https://www.postgresql.org/docs/12/extend-extensions.html)
is an integral part of Promscale. It is required to be installed.
Check the [release notes](https://github.com/timescale/promscale/releases/tag/0.11.0)
for more details.

The extension plays two important roles: 
1. It manages the SQL data schema and [migrations](migration/README.md) that manipulate it.
2. It encompasses code that runs within a database instance, both PL/pgSQL and native.

## Motivation

It's fairly common for backend applications to manage their database schema via a migration
system. Altering a table and adding an index are typical operations that come to mind.
As Promscale grew in scope and complexity we found ourselves defining custom data types,
aggregates and background jobs. Having the extension manage both the migration logic and
various extensions helps to deal with situations when one depends on the other.

Yet, developer convenience is not the main reason this extension exists. It enables complex
optimizations for both PromQL and SQL users. Let's have a look at two examples.

Custom aggregates like `prom_rate`, `prom_delta` and a few others are implemented in Rust
and enable Promscale to push corresponding PromQL down to native code that is executed
within PostgreSQL. The alternatives are either transferring all the data to the Promscale
application and doing aggregation there, or a PL/pgSQL stored procedure. Both are substantially slower.

[Support functions](https://www.postgresql.org/docs/current/xfunc-optimization.html) that
transparently rewrite some queries to reduce the amount of computation required or take
advantage of indices and tables specific to Promscale. For instance, the following query:

```SQL
SELECT trace_id
    FROM ps_trace.span
    WHERE
            span_tags -> 'pwlen' = '25'::jsonb
        AND resource_tags -> 'service.name' = '"generator"';
```

will have an additional `InitPlan` stage that precomputes a set of matching tags,
then uses a GIN index on a private `_ps_trace.span` table. While the naive version
can only evaluate matching tags per row.

## Requirements

To run the extension:

- PostgreSQL version 12 or newer.

To compile the extension (see instructions below):

- Rust compiler
- PGX framework

## Installation

- [Precompiled OS Packages](./INSTALL.md#precompiled-os-packages)
- [Docker images](./INSTALL.md#docker-images)
- [Compile From Source](./INSTALL.md#compile-from-source)

## Development

To quickly setup a development environment, see [DEVELOPMENT.md](DEVELOPMENT.md)
To understand more about how to write SQL migration files for this extension, consult [this](migration/README.md) guide.
To get a better understanding of our CI pipeline see [this document](.github/workflows/README.md).

## Releasing

A full checklist of the steps necessary to release a new version of the extension is available in [RELEASING.md](RELEASING.md).