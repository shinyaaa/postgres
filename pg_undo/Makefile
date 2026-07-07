# pg_undo/Makefile

MODULE_big = pg_undo
OBJS = \
	$(WIN32RES) \
	pg_undo.o \
	pg_undo_plugin.o \
	pg_undo_worker.o

EXTENSION = pg_undo
DATA = pg_undo--0.1.sql
PGFILEDESC = "pg_undo - undo accidental DML using logical decoding"

REGRESS = pg_undo
REGRESS_OPTS = --temp-config $(CURDIR)/pg_undo.conf
# shared_preload_libraries and wal_level cannot be applied to a running
# server, so installcheck is not supported.
NO_INSTALLCHECK = 1

TAP_TESTS = 1

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
