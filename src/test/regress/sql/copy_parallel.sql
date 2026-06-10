--
-- Parallel COPY FROM
--
-- Note: the PARALLEL option falls back to serial execution whenever the
-- operation is not eligible or no workers can be launched, producing the
-- same results, so all data assertions here are independent of how many
-- workers actually run.  Only the end-of-copy marker test relies on a
-- worker being launched, like other parallel tests in this suite.
--

-- directory paths are passed to us in environment variables
\getenv abs_builddir PG_ABS_BUILDDIR

\set filename :abs_builddir '/results/copy_parallel.data'

--
-- Basic round trip: enough data for several 64kB ranges
--
create table parcopy_src (id int, t text, n numeric);
insert into parcopy_src
  select g, 'row ' || g, g * 0.001 from generate_series(1, 50000) g;
copy parcopy_src to :'filename';

create table parcopy_tgt (like parcopy_src);
copy parcopy_tgt from :'filename' with (parallel 2);
select count(*) from parcopy_tgt;
select * from parcopy_src except select * from parcopy_tgt;
select * from parcopy_tgt except select * from parcopy_src;

-- PARALLEL 0 explicitly requests serial execution
truncate parcopy_tgt;
copy parcopy_tgt from :'filename' with (parallel 0);
select count(*) from parcopy_tgt;

--
-- Values wide enough to be toasted by the workers
--
create table parcopy_toast (id int, big text);
insert into parcopy_toast
  select g, repeat('x', 100000) || g from generate_series(1, 40) g;
copy parcopy_toast to :'filename';

create table parcopy_toast2 (like parcopy_toast);
copy parcopy_toast2 from :'filename' with (parallel 2);
select count(*), sum(length(big)) from parcopy_toast2;
select * from parcopy_toast except select * from parcopy_toast2;

--
-- Adversarial backslashes: fields ending in backslash runs (escaped to
-- even-length runs before the newline), and literal escaped newlines
-- (a backslash immediately followed by a newline), which must not be
-- mistaken for line boundaries when splitting the file.
--
create table parcopy_bs (id int, t text);
insert into parcopy_bs
  select g, 'x' || repeat('\', g % 5) from generate_series(1, 20000) g;
copy parcopy_bs to :'filename';

create table parcopy_bs2 (like parcopy_bs);
copy parcopy_bs2 from :'filename' with (parallel 2);
select * from parcopy_bs except select * from parcopy_bs2;
select * from parcopy_bs2 except select * from parcopy_bs;

-- write "<id> TAB ab\<newline>cd" lines: an escaped literal newline
\pset tuples_only on
\pset format unaligned
\o :filename
select g::text || E'\tab\\\ncd' from generate_series(1, 20000) g;
\o
\pset format aligned
\pset tuples_only off

create table parcopy_esc (id int, t text);
create table parcopy_esc2 (like parcopy_esc);
copy parcopy_esc from :'filename';
copy parcopy_esc2 from :'filename' with (parallel 2);
select count(*), count(distinct t) from parcopy_esc2;
select * from parcopy_esc except select * from parcopy_esc2;
select * from parcopy_esc2 except select * from parcopy_esc;

--
-- HEADER handling: only the process reading the start of the file skips
-- and validates the header line
--
copy parcopy_src to :'filename' with (header);
truncate parcopy_tgt;
copy parcopy_tgt from :'filename' with (header, parallel 2);
select count(*) from parcopy_tgt;
truncate parcopy_tgt;
copy parcopy_tgt from :'filename' with (header match, parallel 2);
select count(*) from parcopy_tgt;

-- header mismatch is detected wherever the header is processed
create table parcopy_hdr (wrong int, names text, here numeric);
\set VERBOSITY terse
copy parcopy_hdr from :'filename' with (header match, parallel 2);
\set VERBOSITY default

--
-- End-of-copy marker in the middle of the file: a serial COPY silently
-- stops there, so a parallel COPY must refuse rather than load the rest.
-- (The error message contains the file path, so re-raise a stable one.)
--
\pset tuples_only on
\pset format unaligned
\o :filename
select case when g = 10000 then E'\\.'
            else g::text || E'\tval ' || g end
  from generate_series(1, 20000) g;
\o
\pset format aligned
\pset tuples_only off

create table parcopy_eocm (id int, t text);
copy parcopy_eocm from :'filename';
select count(*) from parcopy_eocm;  -- serial COPY stops at the marker

create function parcopy_expect_eocm_error(path text) returns text as $$
begin
  execute format('copy parcopy_eocm from %L with (parallel 2)', path);
  return 'unexpectedly succeeded';
exception when bad_copy_file_format then
  return 'bad_copy_file_format raised';
end $$ language plpgsql;

truncate parcopy_eocm;
select parcopy_expect_eocm_error(:'filename');
select count(*) from parcopy_eocm;  -- nothing may have been loaded

-- ... but a trailing marker at the very end of the file is fine
\pset tuples_only on
\pset format unaligned
\o :filename
select g::text || E'\tval ' || g from generate_series(1, 20000) g
union all select E'\\.';
\o
\pset format aligned
\pset tuples_only off
truncate parcopy_eocm;
copy parcopy_eocm from :'filename' with (parallel 2);
select count(*) from parcopy_eocm;

--
-- Errors detected while loading abort the whole COPY
--
copy parcopy_src to :'filename';
create table parcopy_uniq (id int primary key, t text, n numeric);
\set VERBOSITY terse
-- a duplicate inserted by another participant is detected
begin;
insert into parcopy_uniq values (25000, 'pre-existing', 0);
copy parcopy_uniq from :'filename' with (parallel 2);
rollback;
\set VERBOSITY default
select count(*) from parcopy_uniq;

--
-- Ineligible cases silently fall back to serial execution with
-- identical results
--

-- CSV format
copy parcopy_src to :'filename' with (format csv);
truncate parcopy_tgt;
copy parcopy_tgt from :'filename' with (format csv, parallel 2);
select count(*) from parcopy_tgt;

copy parcopy_src to :'filename';

-- STDIN source
create table parcopy_stdin (a int, b text);
copy parcopy_stdin from stdin with (parallel 2);
1	one
2	two
\.
select * from parcopy_stdin order by a;

-- temporary table
create temp table parcopy_temp (like parcopy_src);
copy parcopy_temp from :'filename' with (parallel 2);
select count(*) from parcopy_temp;

-- INSERT trigger
create table parcopy_trig (like parcopy_src);
create function parcopy_trigfn() returns trigger as
  $$ begin return new; end $$ language plpgsql;
create trigger parcopy_befrow before insert on parcopy_trig
  for each row execute function parcopy_trigfn();
copy parcopy_trig from :'filename' with (parallel 2);
select count(*) from parcopy_trig;

-- foreign key (an after-row trigger internally)
create table parcopy_pk (id int primary key);
insert into parcopy_pk select g from generate_series(1, 50000) g;
create table parcopy_fk (id int references parcopy_pk, t text, n numeric);
copy parcopy_fk from :'filename' with (parallel 2);
select count(*) from parcopy_fk;

-- serial column not supplied by the input (nextval() is parallel unsafe)
create table parcopy_serial (id int, t text, n numeric, s serial);
copy parcopy_serial (id, t, n) from :'filename' with (parallel 2);
select count(*), max(s) from parcopy_serial;

-- ON_ERROR requires serial execution
truncate parcopy_tgt;
copy parcopy_tgt from :'filename' with (parallel 2, on_error ignore);
select count(*) from parcopy_tgt;

--
-- Option validation (option errors are raised before the file is opened,
-- so a dummy relative path keeps the output stable)
--
copy parcopy_src to 'dummy.data' with (parallel 2);  -- fail: COPY TO
copy parcopy_tgt from 'dummy.data' with (parallel -1);	-- fail: negative
copy parcopy_tgt from 'dummy.data' with (parallel 2, parallel 4);  -- fail: dup

-- clean up
drop function parcopy_expect_eocm_error(text);
drop function parcopy_trigfn() cascade;
drop table parcopy_src, parcopy_tgt, parcopy_toast, parcopy_toast2,
  parcopy_bs, parcopy_bs2, parcopy_esc, parcopy_esc2, parcopy_hdr,
  parcopy_eocm, parcopy_uniq, parcopy_stdin, parcopy_trig,
  parcopy_fk, parcopy_pk, parcopy_serial;
