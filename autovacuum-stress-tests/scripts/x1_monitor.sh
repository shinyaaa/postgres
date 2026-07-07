#!/bin/bash
export PATH=/home/user/pgav/bin:$PATH
for i in $(seq 1 360); do
  ts=$(date +%H:%M:%S)
  line=$(psql -d postgres -Atc "SELECT phase||'|scanned='||heap_blks_scanned||'|vacuumed='||heap_blks_vacuumed||'|idx_vac_count='||index_vacuum_count||'|dtb='||dead_tuple_bytes||'|max_dtb='||max_dead_tuple_bytes||'|num_dead='||num_dead_item_ids FROM pg_stat_progress_vacuum")
  if [ -z "$line" ]; then line="(no active vacuum)"; fi
  echo "${i} ${ts} ${line}"
  sleep 5
done
