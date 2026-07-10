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

-- EXPLAIN ANALYZE of a query-based COPY TO executes the source query,
-- but produces no COPY output: no file is written, and no data is sent
-- to the client.
explain (analyze, costs off, timing off, summary off, buffers off)
  copy (select * from explain_copy_tbl where a > 0) to stdout;
explain (analyze, costs off, timing off, summary off, buffers off)
  copy (select a from explain_copy_tbl) to '/no/such/dir/file';

-- invalid cases
explain copy explain_copy_no_such_table from stdin;
explain copy explain_copy_tbl from stdin with (format nosuch);
explain (analyze) copy explain_copy_tbl from stdin;
explain (analyze) copy explain_copy_tbl to stdout;

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

--
-- EXPLAIN ANALYZE COPY FROM executes the COPY and reports a breakdown of
-- the execution.  (The timing values are not stable, so the breakdown
-- itself is exercised with TIMING OFF, which omits it.)
--
\getenv abs_builddir PG_ABS_BUILDDIR
\set filename :abs_builddir '/results/explain_copy.data'
copy explain_copy_tbl to :'filename';

create table explain_copy_target (a int, b text);
create index explain_copy_target_idx on explain_copy_target (a);

-- The File property of the output contains the absolute build directory
-- path, so filter it out.
create function explain_copy_filter(cmd text) returns setof text
language plpgsql as
$$
declare
    ln text;
begin
    for ln in execute cmd loop
        ln := regexp_replace(ln, '(File|Program): .*', '\1: ...');
        return next ln;
    end loop;
end;
$$;

begin;
select explain_copy_filter(
  'explain (analyze, timing off, summary off, buffers off) '
  'copy explain_copy_target from ' || quote_literal(:'filename'));
-- the data is actually loaded ...
select count(*) from explain_copy_target;
rollback;
-- ... and was rolled back with the transaction
select count(*) from explain_copy_target;

-- rows excluded by the WHERE clause are reported
begin;
select explain_copy_filter(
  'explain (analyze, timing off, summary off, buffers off) '
  'copy explain_copy_target from ' || quote_literal(:'filename')
  || ' where a > 1');
rollback;

-- trigger statistics are reported
create function explain_copy_trigf() returns trigger language plpgsql
  as $$ begin return new; end $$;
create trigger explain_copy_trig before insert on explain_copy_target
  for each row execute function explain_copy_trigf();
begin;
select explain_copy_filter(
  'explain (analyze, timing off, summary off, buffers off) '
  'copy explain_copy_target from ' || quote_literal(:'filename'));
rollback;
drop trigger explain_copy_trig on explain_copy_target;
drop function explain_copy_trigf();

-- rows skipped because of ON_ERROR are reported
create table explain_copy_texts (a text, b text);
insert into explain_copy_texts values ('1', 'one'), ('bogus', 'two'), ('3', 'three');
\set badfile :abs_builddir '/results/explain_copy_bad.data'
copy explain_copy_texts to :'badfile';
begin;
select explain_copy_filter(
  'explain (analyze, timing off, summary off, buffers off) '
  'copy explain_copy_target from ' || quote_literal(:'badfile')
  || ' with (on_error ignore)');
rollback;
drop table explain_copy_texts;

-- a partitioned table can be the target
create table explain_copy_part (a int, b text) partition by range (a);
create table explain_copy_part1 partition of explain_copy_part
  for values from (0) to (2);
create table explain_copy_part2 partition of explain_copy_part
  for values from (2) to (100);
begin;
select explain_copy_filter(
  'explain (analyze, timing off, summary off, buffers off) '
  'copy explain_copy_part from ' || quote_literal(:'filename'));
rollback;
drop table explain_copy_part;

-- ANALYZE cannot be used with COPY FROM STDIN
explain (analyze) copy explain_copy_target from stdin;

-- nor in a read-only transaction
begin transaction read only;
explain (analyze, timing off, summary off, buffers off)
  copy explain_copy_target from :'filename';
rollback;

drop function explain_copy_filter(text);
drop table explain_copy_target;
drop table explain_copy_tbl;
