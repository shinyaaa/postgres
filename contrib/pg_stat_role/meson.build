# Copyright (c) 2026, PostgreSQL Global Development Group

pg_stat_role_sources = files(
  'pg_stat_role.c',
)

if host_system == 'windows'
  pg_stat_role_sources += rc_lib_gen.process(win32ver_rc, extra_args: [
    '--NAME', 'pg_stat_role',
    '--FILEDESC', 'pg_stat_role - cumulative per-role resource usage statistics',])
endif

pg_stat_role = shared_module('pg_stat_role',
  pg_stat_role_sources,
  kwargs: contrib_mod_args,
)
contrib_targets += pg_stat_role

install_data(
  'pg_stat_role.control',
  'pg_stat_role--1.0.sql',
  kwargs: contrib_data_args,
)

tests += {
  'name': 'pg_stat_role',
  'sd': meson.current_source_dir(),
  'bd': meson.current_build_dir(),
  'regress': {
    'sql': [
      'pg_stat_role',
    ],
    'regress_args': ['--temp-config', files('pg_stat_role.conf')],
    # Disabled because these tests require
    # "shared_preload_libraries=pg_stat_role", which typical
    # runningcheck users do not have (e.g. buildfarm clients).
    'runningcheck': false,
  },
}
