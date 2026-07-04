#!/bin/bash
# (d) Repeated CREATE/DROP of tables + functions to churn stat entry create/destroy
# (relation, index, and function stat kinds). Each process uses a private namespace.
source /home/user/stress/env.sh
tag=$$
i=0
while :; do
  n=$((i % 25))
  t="st_${tag}_${n}"
  f="stf_${tag}_${n}"
  $PSQL >/dev/null 2>&1 <<SQL
CREATE TABLE IF NOT EXISTS $t (a int primary key, b text);
INSERT INTO $t SELECT g, 'x' FROM generate_series(1,20) g ON CONFLICT DO NOTHING;
CREATE OR REPLACE FUNCTION $f() RETURNS bigint LANGUAGE sql AS 'SELECT count(*) FROM $t';
SELECT $f();
SELECT * FROM $t WHERE a < 5;
DROP FUNCTION $f();
DROP TABLE $t;
SQL
  i=$((i+1))
done
