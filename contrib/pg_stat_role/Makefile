# contrib/pg_stat_role/Makefile

MODULE_big = pg_stat_role
OBJS = \
	$(WIN32RES) \
	pg_stat_role.o

EXTENSION = pg_stat_role
DATA = pg_stat_role--1.0.sql
PGFILEDESC = "pg_stat_role - cumulative per-role resource usage statistics"

REGRESS_OPTS = --temp-config $(top_srcdir)/contrib/pg_stat_role/pg_stat_role.conf
REGRESS = pg_stat_role

# Disabled because these tests require "shared_preload_libraries=pg_stat_role",
# which typical installcheck users do not have (e.g. buildfarm clients).
NO_INSTALLCHECK = 1

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pg_stat_role
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
