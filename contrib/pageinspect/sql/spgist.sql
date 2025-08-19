-- contrib/pageinspect/sql/spgist.sql
-- Test SP-GiST inspection functions
CREATE EXTENSION IF NOT EXISTS pageinspect;
CREATE TABLE test_spgist (p point);
-- Use an unlogged table so that the contents are not WAL-logged, which makes
-- the output more stable.
CREATE UNLOGGED TABLE test_spgist_unlogged (p point);
INSERT INTO test_spgist_unlogged SELECT point(i,i) FROM generate_series(1,100) i;
CREATE INDEX test_spgist_idx ON test_spgist_unlogged USING spgist (p);
-- Test spgist_page_type
-- Page 0 is the metapage
SELECT spgist_page_type(get_raw_page('test_spgist_idx', 0));

-- Page 1 is the root inner page
SELECT spgist_page_type(get_raw_page('test_spgist_idx', 1));

-- Page 2 should be a leaf page
SELECT spgist_page_type(get_raw_page('test_spgist_idx', 2));

-- Test spgist_metapage_info
SELECT * FROM spgist_metapage_info(get_raw_page('test_spgist_idx', 0));

-- Test on a non-metapage, should fail
SELECT * FROM spgist_metapage_info(get_raw_page('test_spgist_idx', 1));
-- Failure cases
\set VERBOSITY terse
-- Non-SP-GiST index
CREATE INDEX test_spgist_gist_idx ON test_spgist_unlogged USING gist (p);
SELECT spgist_page_type(get_raw_page('test_spgist_gist_idx', 0));
-- Non-page data
SELECT spgist_page_type('aaa'::bytea);
SELECT spgist_metapage_info('aaa'::bytea);
-- all-zero pages
SHOW block_size \gset
SELECT spgist_page_type(decode(repeat('00', :block_size), 'hex'));
SELECT spgist_metapage_info(decode(repeat('00', :block_size), 'hex'));
\set VERBOSITY default
DROP TABLE test_spgist;
DROP TABLE test_spgist_unlogged;
