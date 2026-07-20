\set ON_ERROR_STOP 0
SET ROLE alice;
\echo '=== COPY t TO (direct) under RLS: ==='
COPY t TO STDOUT;
\echo '=== COPY (SELECT * FROM t) TO: should honor RLS (alice rows only) ==='
COPY (SELECT * FROM t) TO STDOUT;
RESET ROLE;
