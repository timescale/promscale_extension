# Development environment

In order to get started developing the extension, you need a postgres install
with timescaledb, and Rust dependencies. For more information, see the
[compile from source](INSTALL.md#Compile From Source) install instructions.

To spare you the effort of getting this set up yourself, we provide a docker
image with all required dependencies, which allows you to just get started.

Run `make devenv` to build the docker image, start it, and expose it on port
54321 on your local machine. This docker image mounts the current directory
into the `/code` directory in the container. By default, it runs postgres 14
and continually recompiles and reinstalls the promscale extension on source
modifications. This means that you can edit the sources locally, and run tests
against the container.

You can adjust the postgres version through the `DEVENV_PG_VERSION` env var,
for example: `DEVENV_PG_VERSION=12 make devenv`

The `POSTGRES_URL` environment variable is used by tests and tools in this repo
to point to a specific postgres installation. If you want to use the image
above, set `POSTGRES_URL=postgres://ubuntu@localhost:54321/`.

The `devenv-url` and `devenv-export-url` make targets output the URL above in
convenient formats, for example:

- To connect to the devenv db with psql: `psql $(make devenv-url)`
- To set the `POSTGRES_URL` for all subshells: `eval $(make devenv-export-url`

To permanently configure `POSTGRES_URL` when you change into this directory,
you may consider using a tool like [direnv](https://direnv.net/).