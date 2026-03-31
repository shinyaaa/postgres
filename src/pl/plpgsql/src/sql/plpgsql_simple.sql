--
-- Tests for plpgsql's handling of "simple" expressions
--

-- Check that changes to an inline-able function are handled correctly
create function simplesql(int) returns int language sql
as 'select $1';

create function simplecaller() returns int language plpgsql
as $$
declare
  sum int := 0;
begin
  for n in 1..10 loop
    sum := sum + simplesql(n);
    if n = 5 then
      create or replace function simplesql(int) returns int language sql
      as 'select $1 + 100';
    end if;
  end loop;
  return sum;
end$$;

select simplecaller();


-- Check that changes in search path are dealt with correctly
create schema simple1;

create function simple1.simpletarget(int) returns int language plpgsql
as $$begin return $1; end$$;

create function simpletarget(int) returns int language plpgsql
as $$begin return $1 + 100; end$$;

create or replace function simplecaller() returns int language plpgsql
as $$
declare
  sum int := 0;
begin
  for n in 1..10 loop
    sum := sum + simpletarget(n);
    if n = 5 then
      set local search_path = 'simple1';
    end if;
  end loop;
  return sum;
end$$;

select simplecaller();

-- try it with non-volatile functions, too
alter function simple1.simpletarget(int) immutable;
alter function simpletarget(int) immutable;

select simplecaller();

-- make sure flushing local caches changes nothing
\c -

select simplecaller();


-- Check case where first attempt to determine if it's simple fails

create function simplesql() returns int language sql
as $$select 1 / 0$$;

create or replace function simplecaller() returns int language plpgsql
as $$
declare x int;
begin
  select simplesql() into x;
  return x;
end$$;

select simplecaller();  -- division by zero occurs during simple-expr check

create or replace function simplesql() returns int language sql
as $$select 2 + 2$$;

select simplecaller();


-- Check case where called function changes from non-SRF to SRF (bug #18497)

create or replace function simplecaller() returns int language plpgsql
as $$
declare x int;
begin
  x := simplesql();
  return x;
end$$;

select simplecaller();

drop function simplesql();

create function simplesql() returns setof int language sql
as $$select 22 + 22$$;

select simplecaller();

select simplecaller();

-- Check handling of simple expression in a scrollable cursor (bug #18859)

do $$
declare
 p_CurData refcursor;
 val int;
begin
 open p_CurData scroll for select 42;
 fetch p_CurData into val;
 raise notice 'val = %', val;
end; $$;

-- We now optimize "SELECT simple-expr INTO var" using the simple-expression
-- logic.  Verify that error reporting works the same as it did before.

do $$
declare x bigint := 2^30; y int;
begin
  -- overflow during assignment step does not get an extra context line
  select x*x into y;
end $$;

do $$
declare x bigint := 2^30; y int;
begin
  -- overflow during expression evaluation step does get an extra context line
  select x*x*x into y;
end $$;


-- Tests for PL/pgSQL function inlining and fast-path execution optimization
--
-- Simple PL/pgSQL functions that consist of just "BEGIN RETURN <expr>; END"
-- can be inlined by the planner (like SQL functions) or executed via a
-- fast path that skips SPI overhead.

-- Basic inlining test: simple arithmetic function
create function plpgsql_plus100(int) returns int language plpgsql
as $$begin return $1 + 100; end$$;

-- Should produce the same result as inline arithmetic
select plpgsql_plus100(42);
select 42 + 100;

-- Verify it works in aggregate context (the main use case for optimization)
create table plpgsql_inline_test (id int);
insert into plpgsql_inline_test select generate_series(1, 100);

select sum(plpgsql_plus100(id)) from plpgsql_inline_test;
select sum(id + 100) from plpgsql_inline_test;

-- Test with multiple calls in the same query
select sum(plpgsql_plus100(id)), sum(plpgsql_plus100(id))
from plpgsql_inline_test;

-- Test with IMMUTABLE function (more likely to be inlined)
create function plpgsql_multiply(int, int) returns int
language plpgsql immutable
as $$begin return $1 * $2; end$$;

select plpgsql_multiply(6, 7);

-- EXPLAIN should show the function has been inlined (no function call node)
explain (costs off) select plpgsql_plus100(id) from plpgsql_inline_test;

-- Test with named parameters
create function plpgsql_add(a int, b int) returns int
language plpgsql immutable
as $$begin return a + b; end$$;

select plpgsql_add(10, 20);

-- Test that complex PL/pgSQL functions are NOT inlined (they use normal path)
-- Function with local variable declarations
create function plpgsql_not_simple1(int) returns int language plpgsql
as $$
declare
  tmp int;
begin
  tmp := $1 + 100;
  return tmp;
end$$;

select plpgsql_not_simple1(42);

-- Function with EXCEPTION handler (should still work, just not inlined)
create function plpgsql_with_exception(int) returns int language plpgsql
as $$begin
  return $1 + 100;
exception when others then
  return 0;
end$$;

select plpgsql_with_exception(42);

-- Function with multiple statements
create function plpgsql_multi_stmt(int) returns int language plpgsql
as $$begin
  perform 1;
  return $1 + 100;
end$$;

select plpgsql_multi_stmt(42);

-- Test NULL handling
select plpgsql_plus100(NULL);

-- Test with text types
create function plpgsql_concat(text, text) returns text
language plpgsql immutable
as $$begin return $1 || $2; end$$;

select plpgsql_concat('hello', ' world');

-- Clean up
drop table plpgsql_inline_test;
drop function plpgsql_plus100(int);
drop function plpgsql_multiply(int, int);
drop function plpgsql_add(int, int);
drop function plpgsql_not_simple1(int);
drop function plpgsql_with_exception(int);
drop function plpgsql_multi_stmt(int);
drop function plpgsql_concat(text, text);
