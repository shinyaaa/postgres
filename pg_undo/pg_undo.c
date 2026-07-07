/*-------------------------------------------------------------------------
 *
 * pg_undo.c
 *	  Extension entry point: GUC definitions and background worker
 *	  registration.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <limits.h>

#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "utils/guc.h"

#include "pg_undo.h"

PG_MODULE_MAGIC_EXT(
					.name = "pg_undo",
					.version = "0.1"
);

char	   *pg_undo_database = NULL;
bool		pg_undo_enabled = true;
int			pg_undo_naptime = 1;
int			pg_undo_janitor_interval = 60;
char	   *pg_undo_retention = NULL;
int			pg_undo_max_history_size = 10240;
bool		pg_undo_recycle_bin = true;
char	   *pg_undo_trash_retention = NULL;

void		_PG_init(void);

void
_PG_init(void)
{
	BackgroundWorker worker;

	/*
	 * The capture worker and its PGC_POSTMASTER GUC can only be set up at
	 * postmaster start.  (The library also gets loaded as a logical decoding
	 * output plugin, in which case there is nothing to do here.)
	 */
	if (!process_shared_preload_libraries_in_progress)
		return;

	DefineCustomStringVariable("pg_undo.database",
							   "Database in which pg_undo captures history.",
							   NULL,
							   &pg_undo_database,
							   "postgres",
							   PGC_POSTMASTER,
							   0,
							   NULL, NULL, NULL);

	DefineCustomBoolVariable("pg_undo.enabled",
							 "Enables history capture.",
							 NULL,
							 &pg_undo_enabled,
							 true,
							 PGC_SIGHUP,
							 0,
							 NULL, NULL, NULL);

	DefineCustomIntVariable("pg_undo.naptime",
							"Duration between capture cycles.",
							NULL,
							&pg_undo_naptime,
							1,
							1,
							3600,
							PGC_SIGHUP,
							GUC_UNIT_S,
							NULL, NULL, NULL);

	DefineCustomStringVariable("pg_undo.retention",
							   "How long captured history is kept.",
							   "Must be a valid interval value.",
							   &pg_undo_retention,
							   "24 hours",
							   PGC_SIGHUP,
							   0,
							   NULL, NULL, NULL);

	DefineCustomIntVariable("pg_undo.janitor_interval",
							"Duration between retention/failsafe janitor runs.",
							NULL,
							&pg_undo_janitor_interval,
							60,
							1,
							86400,
							PGC_SIGHUP,
							GUC_UNIT_S,
							NULL, NULL, NULL);

	DefineCustomIntVariable("pg_undo.max_history_size",
							"Pause history capture when undo.history exceeds this size.",
							NULL,
							&pg_undo_max_history_size,
							10240,
							1,
							INT_MAX,
							PGC_SIGHUP,
							GUC_UNIT_MB,
							NULL, NULL, NULL);

	DefineCustomBoolVariable("pg_undo.recycle_bin",
							 "Divert DROP TABLE into the undo_trash recycle bin.",
							 "Only superusers can turn this off to drop tables for real; DROP TABLE ... CASCADE always bypasses the bin.",
							 &pg_undo_recycle_bin,
							 true,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomStringVariable("pg_undo.trash_retention",
							   "How long dropped tables are kept in the recycle bin.",
							   "Must be a valid interval value.",
							   &pg_undo_trash_retention,
							   "7 days",
							   PGC_SIGHUP,
							   0,
							   NULL, NULL, NULL);

	MarkGUCPrefixReserved("pg_undo");

	pg_undo_drop_init();

	memset(&worker, 0, sizeof(worker));
	worker.bgw_flags = BGWORKER_SHMEM_ACCESS |
		BGWORKER_BACKEND_DATABASE_CONNECTION;
	worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
	worker.bgw_restart_time = 10;
	snprintf(worker.bgw_library_name, MAXPGPATH, "pg_undo");
	snprintf(worker.bgw_function_name, BGW_MAXLEN, "pg_undo_worker_main");
	snprintf(worker.bgw_name, BGW_MAXLEN, "pg_undo capture worker");
	snprintf(worker.bgw_type, BGW_MAXLEN, "pg_undo capture worker");
	worker.bgw_main_arg = (Datum) 0;
	worker.bgw_notify_pid = 0;

	RegisterBackgroundWorker(&worker);
}
