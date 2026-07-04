#!/bin/bash
# Common environment for stress scripts (run as user "user")
export PGI=/home/user/pgi
export PGDATA=/home/user/pgdata
export PGUSER=postgres
export PGDATABASE=postgres
export PGHOST=/tmp
export PATH="$PGI/bin:$PATH"
# psql that never reads .psqlrc, quiet, stop on error off (we tolerate errors)
PSQL="$PGI/bin/psql -X -q -U postgres -d postgres"
export PSQL
LOGDIR=/home/user/stress/logs
export LOGDIR
