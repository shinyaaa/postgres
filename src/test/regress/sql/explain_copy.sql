--
-- Tests for EXPLAIN of COPY statements
--
create table explain_copy_tbl (a int, b text);
insert into explain_copy_tbl values (1, 'one'), (2, 'two');

-- Plain EXPLAIN does not execute the COPY, and does not access the
-- source/destination file.
explain copy explain_copy_tbl from '/no/such/file';
explain (verbose) copy explain_copy_tbl to '/no/such/file' with (format binary);
explain copy explain_copy_tbl from stdin with (format csv, on_error ignore);
explain copy explain_copy_tbl (a) from program '/no/such/program';
explain copy explain_copy_tbl to stdout;

-- The plan of the source query of COPY (query) TO is shown.
explain (costs off) copy (select * from explain_copy_tbl where a > 0) to stdout;
explain (costs off, format json) copy (select a from explain_copy_tbl) to stdout (format csv);

-- invalid cases
explain copy explain_copy_no_such_table from stdin;
explain copy explain_copy_tbl from stdin with (format nosuch);
explain (analyze) copy explain_copy_tbl from stdin;
explain (analyze) copy explain_copy_tbl to stdout;
explain (analyze) copy (select 1) to stdout;

-- Plain EXPLAIN performs the same permission checks as COPY would.
create role regress_explain_copy;
grant select, insert on explain_copy_tbl to regress_explain_copy;
set role regress_explain_copy;
explain copy explain_copy_tbl from '/no/such/file';	-- fail, no file access
explain copy explain_copy_tbl from stdin;
reset role;

-- Row-level security converts COPY relation TO into a query-based COPY.
create table explain_copy_rls (a int);
insert into explain_copy_rls values (1), (-1);
alter table explain_copy_rls enable row level security;
create policy explain_copy_policy on explain_copy_rls
  for select using (a > 0);
grant select on explain_copy_rls to regress_explain_copy;
set role regress_explain_copy;
explain (costs off) copy explain_copy_rls to stdout;
reset role;

revoke all on explain_copy_tbl from regress_explain_copy;
revoke all on explain_copy_rls from regress_explain_copy;
drop role regress_explain_copy;
drop table explain_copy_rls;
drop table explain_copy_tbl;
