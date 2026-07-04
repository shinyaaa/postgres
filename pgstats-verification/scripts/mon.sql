-- Normalized snapshot of all pg_stat_reset_shared-affected views.
-- One row per view: label, stats_reset timestamp, a representative counter sum.
SELECT 'archiver'     AS v, max(stats_reset)::text AS ts, coalesce(sum(archived_count+failed_count),0) AS val FROM pg_stat_archiver
UNION ALL SELECT 'bgwriter',     stats_reset::text, coalesce(buffers_clean+maxwritten_clean,0) FROM pg_stat_bgwriter
UNION ALL SELECT 'checkpointer', stats_reset::text, coalesce(num_timed+num_requested+buffers_written,0) FROM pg_stat_checkpointer
UNION ALL SELECT 'io',           max(stats_reset)::text, coalesce(sum(reads+writes+extends+hits+evictions),0) FROM pg_stat_io
UNION ALL SELECT 'wal',          stats_reset::text, coalesce(wal_records,0) FROM pg_stat_wal
UNION ALL SELECT 'slru',         max(stats_reset)::text, coalesce(sum(blks_hit+blks_read+blks_written+blks_zeroed),0) FROM pg_stat_slru
UNION ALL SELECT 'lock',         max(stats_reset)::text, coalesce(sum(waits),0) FROM pg_stat_lock
UNION ALL SELECT 'recovery_prefetch', stats_reset::text, coalesce(prefetch+hit,0) FROM pg_stat_recovery_prefetch
ORDER BY v;
