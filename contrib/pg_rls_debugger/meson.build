# Copyright (c) 2026, PostgreSQL Global Development Group

install_data(
  'pg_rls_debugger--1.0.sql',
  'pg_rls_debugger.control',
  kwargs: contrib_data_args,
)

tests += {
  'name': 'pg_rls_debugger',
  'sd': meson.current_source_dir(),
  'bd': meson.current_build_dir(),
  'regress': {
    'sql': [
      'pg_rls_debugger',
    ],
  },
}
