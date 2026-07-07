SELECT name, setting, unit FROM pg_settings
WHERE name IN ('autovacuum_work_mem','maintenance_work_mem','autovacuum_naptime',
'autovacuum_vacuum_cost_delay','log_autovacuum_min_duration','autovacuum','shared_buffers');
