# contrib/pg_rls_debugger/Makefile

EXTENSION = pg_rls_debugger
DATA = pg_rls_debugger--1.0.sql
PGFILEDESC = "pg_rls_debugger - debugger for row-level security policies"

REGRESS = pg_rls_debugger

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pg_rls_debugger
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
