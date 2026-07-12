/*-------------------------------------------------------------------------
 *
 * pg_stat_role.c
 *		Cumulative per-role resource usage statistics.
 *
 * This module accumulates, per role (keyed by role OID, cluster-wide),
 * the resources consumed by SQL statements: statement and row counts,
 * execution time, CPU time (getrusage), block I/O (BufferUsage) and
 * WAL usage (WalUsage).
 *
 * Statement deltas are captured with ExecutorStart/ExecutorEnd and
 * ProcessUtility hooks, accumulated in a backend-local pending entry,
 * and flushed to shared memory through the standard cumulative
 * statistics machinery (custom variable-numbered stats kind).
 *
 * A whole statement is attributed to the user returned by GetUserId()
 * at statement start, following the precedent of pg_stat_statements.
 * Resources consumed inside SECURITY DEFINER functions are therefore
 * charged to the caller, not to the function owner.
 *
 * Copyright (c) 2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  contrib/pg_stat_role/pg_stat_role.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <sys/resource.h>

#include "access/parallel.h"
#include "catalog/objectaccess.h"
#include "catalog/pg_authid.h"
#include "executor/executor.h"
#include "executor/instrument.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "portability/instr_time.h"
#include "tcop/utility.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/pgstat_internal.h"
#include "utils/syscache.h"
#include "utils/timestamp.h"
#include "utils/tuplestore.h"

PG_MODULE_MAGIC_EXT(
					.name = "pg_stat_role",
					.version = PG_VERSION
);

/*
 * Kind ID for pg_stat_role statistics.
 *
 * PGSTAT_KIND_EXPERIMENTAL is meant for extensions still in development
 * that have not reserved their own ID yet.  Loading two extensions that
 * both use this ID will fail at startup.  Before any serious use, get a
 * unique ID assigned at
 * https://wiki.postgresql.org/wiki/CustomCumulativeStats
 */
#define PGSTAT_KIND_ROLE	PGSTAT_KIND_EXPERIMENTAL

/*
 * Per-role counters.  Used both for the backend-local pending entry and
 * (embedded in PgStatShared_RoleEntry) for the shared entry, like the
 * built-in variable-numbered kinds do.
 *
 * Times are in milliseconds.  stat_reset_timestamp is only meaningful in
 * the shared entry.
 */
typedef struct PgStat_StatRoleEntry
{
	PgStat_Counter statements;	/* # of top-level statements */
	PgStat_Counter rows;		/* # of rows retrieved or affected */
	double		total_exec_time;	/* wall-clock time */
	double		cpu_user_time;	/* getrusage user CPU time */
	double		cpu_system_time;	/* getrusage system CPU time */
	PgStat_Counter vol_context_switches;	/* voluntary context switches */
	PgStat_Counter invol_context_switches;	/* involuntary context switches */
	PgStat_Counter shared_blks_hit;
	PgStat_Counter shared_blks_read;
	PgStat_Counter shared_blks_dirtied;
	PgStat_Counter shared_blks_written;
	PgStat_Counter local_blks_hit;
	PgStat_Counter local_blks_read;
	PgStat_Counter local_blks_dirtied;
	PgStat_Counter local_blks_written;
	PgStat_Counter temp_blks_read;
	PgStat_Counter temp_blks_written;
	PgStat_Counter wal_records;
	PgStat_Counter wal_fpi;
	uint64		wal_bytes;
	TimestampTz stat_reset_timestamp;
} PgStat_StatRoleEntry;

/* Shared memory entry, one per role OID */
typedef struct PgStatShared_RoleEntry
{
	PgStatShared_Common header;
	PgStat_StatRoleEntry stats;
} PgStatShared_RoleEntry;

/*
 * Backend-local state of the currently tracked top-level statement.
 *
 * A single static slot suffices because only statements starting at
 * nesting level 0 are tracked.  The queryDesc pointer is remembered so
 * that an ExecutorEnd for a different query (e.g. a portal from an
 * earlier, interleaved statement) does not consume a stale snapshot.
 */
typedef struct pgsrExecState
{
	bool		active;
	QueryDesc  *qd;
	Oid			userid;
	instr_time	start_time;
	struct rusage ru_start;
	BufferUsage buf_start;
	WalUsage	wal_start;
} pgsrExecState;

static pgsrExecState exec_state;

/*
 * Nesting depth of ExecutorRun / ProcessUtility calls, as in
 * pg_stat_statements.  Only level-0 statements are tracked, so that SQL
 * executed inside functions or utility commands is charged (once) to the
 * enclosing top-level statement.
 */
static int	nesting_level = 0;

/* Saved hook values */
static ExecutorStart_hook_type prev_ExecutorStart = NULL;
static ExecutorRun_hook_type prev_ExecutorRun = NULL;
static ExecutorFinish_hook_type prev_ExecutorFinish = NULL;
static ExecutorEnd_hook_type prev_ExecutorEnd = NULL;
static ProcessUtility_hook_type prev_ProcessUtility = NULL;
static object_access_hook_type prev_object_access_hook = NULL;

/* GUC: pg_stat_role.track */
static bool pgsr_track = true;

/* true once our stats kind has been registered */
static bool pgsr_kind_registered = false;

/*---- Function declarations ----*/

PG_FUNCTION_INFO_V1(pg_stat_role_entries);
PG_FUNCTION_INFO_V1(pg_stat_role_reset);
PG_FUNCTION_INFO_V1(pg_stat_role_gc);

static bool pgsr_flush_pending_cb(PgStat_EntryRef *entry_ref, bool nowait);
static void pgsr_reset_timestamp_cb(PgStatShared_Common *header, TimestampTz ts);

static void pgsr_ExecutorStart(QueryDesc *queryDesc, int eflags);
static void pgsr_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction,
							 uint64 count);
static void pgsr_ExecutorFinish(QueryDesc *queryDesc);
static void pgsr_ExecutorEnd(QueryDesc *queryDesc);
static void pgsr_ProcessUtility(PlannedStmt *pstmt, const char *queryString,
								bool readOnlyTree,
								ProcessUtilityContext context,
								ParamListInfo params,
								QueryEnvironment *queryEnv,
								DestReceiver *dest, QueryCompletion *qc);
static void pgsr_object_access(ObjectAccessType access, Oid classId,
							   Oid objectId, int subId, void *arg);

/*
 * Definition of our custom cumulative statistics kind.
 *
 * write_to_file makes the standard machinery serialize the entries into
 * the pgstats file at shutdown and restore them at startup, so counters
 * survive clean restarts.  No auxiliary serialization callbacks are
 * needed: the OID key and the fixed-size stats data are enough.
 */
static const PgStat_KindInfo pgsr_stats_kind = {
	.name = "pg_stat_role",
	.fixed_amount = false,
	.write_to_file = true,
	.track_entry_count = true,
	.accessed_across_databases = true,
	.shared_size = sizeof(PgStatShared_RoleEntry),
	.shared_data_off = offsetof(PgStatShared_RoleEntry, stats),
	.shared_data_len = sizeof(((PgStatShared_RoleEntry *) 0)->stats),
	.pending_size = sizeof(PgStat_StatRoleEntry),
	.flush_pending_cb = pgsr_flush_pending_cb,
	.reset_timestamp_cb = pgsr_reset_timestamp_cb,
};

/*
 * Module load callback
 */
void
_PG_init(void)
{
	if (!process_shared_preload_libraries_in_progress)
		ereport(ERROR,
				(errmsg("pg_stat_role must be loaded via \"shared_preload_libraries\"")));

	DefineCustomBoolVariable("pg_stat_role.track",
							 "Selects whether per-role statistics are collected.",
							 NULL,
							 &pgsr_track,
							 true,
							 PGC_SUSET,
							 0,
							 NULL,
							 NULL,
							 NULL);

	MarkGUCPrefixReserved("pg_stat_role");

	pgstat_register_kind(PGSTAT_KIND_ROLE, &pgsr_stats_kind);
	pgsr_kind_registered = true;

	/* Install hooks */
	prev_ExecutorStart = ExecutorStart_hook;
	ExecutorStart_hook = pgsr_ExecutorStart;
	prev_ExecutorRun = ExecutorRun_hook;
	ExecutorRun_hook = pgsr_ExecutorRun;
	prev_ExecutorFinish = ExecutorFinish_hook;
	ExecutorFinish_hook = pgsr_ExecutorFinish;
	prev_ExecutorEnd = ExecutorEnd_hook;
	ExecutorEnd_hook = pgsr_ExecutorEnd;
	prev_ProcessUtility = ProcessUtility_hook;
	ProcessUtility_hook = pgsr_ProcessUtility;
	prev_object_access_hook = object_access_hook;
	object_access_hook = pgsr_object_access;
}

/*
 * Flush callback: merge a backend-local pending entry into the shared
 * entry for the same role.
 */
static bool
pgsr_flush_pending_cb(PgStat_EntryRef *entry_ref, bool nowait)
{
	PgStat_StatRoleEntry *pending;
	PgStatShared_RoleEntry *shent;

	pending = (PgStat_StatRoleEntry *) entry_ref->pending;
	shent = (PgStatShared_RoleEntry *) entry_ref->shared_stats;

	if (!pgstat_lock_entry(entry_ref, nowait))
		return false;

#define PGSR_ACC(fld) shent->stats.fld += pending->fld
	PGSR_ACC(statements);
	PGSR_ACC(rows);
	PGSR_ACC(total_exec_time);
	PGSR_ACC(cpu_user_time);
	PGSR_ACC(cpu_system_time);
	PGSR_ACC(vol_context_switches);
	PGSR_ACC(invol_context_switches);
	PGSR_ACC(shared_blks_hit);
	PGSR_ACC(shared_blks_read);
	PGSR_ACC(shared_blks_dirtied);
	PGSR_ACC(shared_blks_written);
	PGSR_ACC(local_blks_hit);
	PGSR_ACC(local_blks_read);
	PGSR_ACC(local_blks_dirtied);
	PGSR_ACC(local_blks_written);
	PGSR_ACC(temp_blks_read);
	PGSR_ACC(temp_blks_written);
	PGSR_ACC(wal_records);
	PGSR_ACC(wal_fpi);
	PGSR_ACC(wal_bytes);
#undef PGSR_ACC

	pgstat_unlock_entry(entry_ref);

	return true;
}

/*
 * Reset callback: remember when this entry was last reset.  The stats
 * data proper has already been zeroed by the common machinery.
 */
static void
pgsr_reset_timestamp_cb(PgStatShared_Common *header, TimestampTz ts)
{
	((PgStatShared_RoleEntry *) header)->stats.stat_reset_timestamp = ts;
}

/*
 * Difference between two rusage timevals, in milliseconds.
 */
static double
pgsr_timeval_diff_ms(const struct timeval *stop, const struct timeval *start)
{
	double		result;

	result = (double) (stop->tv_sec - start->tv_sec) * 1000.0 +
		(double) (stop->tv_usec - start->tv_usec) / 1000.0;

	return Max(result, 0);
}

/*
 * Accumulate one statement's deltas into the pending entry for userid.
 *
 * In a parallel worker only CPU time and context switches are counted
 * (cpu_only): the worker's buffer and WAL usage are propagated to the
 * leader's counters by the executor and would be double-counted here,
 * while its CPU time is invisible to the leader's getrusage() and would
 * otherwise be lost.
 */
static void
pgsr_accum(Oid userid, bool cpu_only, double exec_ms, uint64 rows,
		   const struct rusage *ru_start, const struct rusage *ru_stop,
		   const BufferUsage *bufusage, const WalUsage *walusage)
{
	PgStat_EntryRef *entry_ref;
	PgStat_StatRoleEntry *pending;

	if (!OidIsValid(userid))
		return;

	entry_ref = pgstat_prep_pending_entry(PGSTAT_KIND_ROLE, InvalidOid,
										  (uint64) userid, NULL);
	pending = (PgStat_StatRoleEntry *) entry_ref->pending;

	pending->cpu_user_time += pgsr_timeval_diff_ms(&ru_stop->ru_utime,
												   &ru_start->ru_utime);
	pending->cpu_system_time += pgsr_timeval_diff_ms(&ru_stop->ru_stime,
													 &ru_start->ru_stime);
#ifndef WIN32
	/* the Windows getrusage() port only fills the CPU time fields */
	pending->vol_context_switches += ru_stop->ru_nvcsw - ru_start->ru_nvcsw;
	pending->invol_context_switches += ru_stop->ru_nivcsw - ru_start->ru_nivcsw;
#endif

	if (cpu_only)
		return;

	pending->statements += 1;
	pending->rows += rows;
	pending->total_exec_time += exec_ms;

	pending->shared_blks_hit += bufusage->shared_blks_hit;
	pending->shared_blks_read += bufusage->shared_blks_read;
	pending->shared_blks_dirtied += bufusage->shared_blks_dirtied;
	pending->shared_blks_written += bufusage->shared_blks_written;
	pending->local_blks_hit += bufusage->local_blks_hit;
	pending->local_blks_read += bufusage->local_blks_read;
	pending->local_blks_dirtied += bufusage->local_blks_dirtied;
	pending->local_blks_written += bufusage->local_blks_written;
	pending->temp_blks_read += bufusage->temp_blks_read;
	pending->temp_blks_written += bufusage->temp_blks_written;

	pending->wal_records += walusage->wal_records;
	pending->wal_fpi += walusage->wal_fpi;
	pending->wal_bytes += walusage->wal_bytes;
}

/*
 * ExecutorStart hook: snapshot resource usage for level-0 statements.
 *
 * The snapshot is taken before running standard_ExecutorStart so that
 * executor initialization is charged to the statement too.
 *
 * This is also reached in parallel workers (ParallelQueryMain goes
 * through ExecutorStart); the worker's slice is recorded CPU-only, see
 * pgsr_accum().
 */
static void
pgsr_ExecutorStart(QueryDesc *queryDesc, int eflags)
{
	if (pgsr_track && nesting_level == 0)
	{
		exec_state.active = true;
		exec_state.qd = queryDesc;
		exec_state.userid = GetUserId();
		exec_state.buf_start = pgBufferUsage;
		exec_state.wal_start = pgWalUsage;
		INSTR_TIME_SET_CURRENT(exec_state.start_time);
		getrusage(RUSAGE_SELF, &exec_state.ru_start);
	}

	if (prev_ExecutorStart)
		prev_ExecutorStart(queryDesc, eflags);
	else
		standard_ExecutorStart(queryDesc, eflags);
}

/*
 * ExecutorRun hook: all we need do is track nesting depth
 */
static void
pgsr_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction, uint64 count)
{
	nesting_level++;
	PG_TRY();
	{
		if (prev_ExecutorRun)
			prev_ExecutorRun(queryDesc, direction, count);
		else
			standard_ExecutorRun(queryDesc, direction, count);
	}
	PG_FINALLY();
	{
		nesting_level--;
	}
	PG_END_TRY();
}

/*
 * ExecutorFinish hook: all we need do is track nesting depth
 */
static void
pgsr_ExecutorFinish(QueryDesc *queryDesc)
{
	nesting_level++;
	PG_TRY();
	{
		if (prev_ExecutorFinish)
			prev_ExecutorFinish(queryDesc);
		else
			standard_ExecutorFinish(queryDesc);
	}
	PG_FINALLY();
	{
		nesting_level--;
	}
	PG_END_TRY();
}

/*
 * ExecutorEnd hook: accumulate this statement's resource usage
 */
static void
pgsr_ExecutorEnd(QueryDesc *queryDesc)
{
	if (exec_state.active && exec_state.qd == queryDesc)
	{
		instr_time	duration;
		struct rusage ru_stop;
		BufferUsage bufusage;
		WalUsage	walusage;

		exec_state.active = false;
		exec_state.qd = NULL;

		getrusage(RUSAGE_SELF, &ru_stop);
		INSTR_TIME_SET_CURRENT(duration);
		INSTR_TIME_SUBTRACT(duration, exec_state.start_time);

		memset(&bufusage, 0, sizeof(BufferUsage));
		BufferUsageAccumDiff(&bufusage, &pgBufferUsage, &exec_state.buf_start);
		memset(&walusage, 0, sizeof(WalUsage));
		WalUsageAccumDiff(&walusage, &pgWalUsage, &exec_state.wal_start);

		pgsr_accum(exec_state.userid,
				   IsParallelWorker(),
				   INSTR_TIME_GET_MILLISEC(duration),
				   queryDesc->estate->es_total_processed,
				   &exec_state.ru_start, &ru_stop,
				   &bufusage, &walusage);
	}

	if (prev_ExecutorEnd)
		prev_ExecutorEnd(queryDesc);
	else
		standard_ExecutorEnd(queryDesc);
}

/*
 * ProcessUtility hook
 *
 * Level-0 utility statements are measured here as a whole.  The nesting
 * level is incremented around the call in all cases, so that optimizable
 * statements executed inside utility commands (CREATE TABLE AS, EXPLAIN
 * ANALYZE, FETCH, ...) are not counted a second time by the executor
 * hooks.
 */
static void
pgsr_ProcessUtility(PlannedStmt *pstmt, const char *queryString,
					bool readOnlyTree,
					ProcessUtilityContext context,
					ParamListInfo params, QueryEnvironment *queryEnv,
					DestReceiver *dest, QueryCompletion *qc)
{
	bool		track;

	track = pgsr_track && nesting_level == 0 && !IsParallelWorker();

	if (track)
	{
		Oid			userid = GetUserId();
		instr_time	start;
		instr_time	duration;
		struct rusage ru_start;
		struct rusage ru_stop;
		BufferUsage bufusage_start;
		BufferUsage bufusage;
		WalUsage	walusage_start;
		WalUsage	walusage;
		uint64		rows;

		bufusage_start = pgBufferUsage;
		walusage_start = pgWalUsage;
		INSTR_TIME_SET_CURRENT(start);
		getrusage(RUSAGE_SELF, &ru_start);

		nesting_level++;
		PG_TRY();
		{
			if (prev_ProcessUtility)
				prev_ProcessUtility(pstmt, queryString, readOnlyTree,
									context, params, queryEnv,
									dest, qc);
			else
				standard_ProcessUtility(pstmt, queryString, readOnlyTree,
										context, params, queryEnv,
										dest, qc);
		}
		PG_FINALLY();
		{
			nesting_level--;
		}
		PG_END_TRY();

		/*
		 * CAUTION: do not access the *pstmt data structure again below
		 * here.  If it was a ROLLBACK or similar, that data structure may
		 * have been freed.
		 */
		pstmt = NULL;

		getrusage(RUSAGE_SELF, &ru_stop);
		INSTR_TIME_SET_CURRENT(duration);
		INSTR_TIME_SUBTRACT(duration, start);

		/*
		 * Count the rows retrieved or affected by utility statements that
		 * report them: COPY, FETCH, CREATE TABLE AS, CREATE MATERIALIZED
		 * VIEW, REFRESH MATERIALIZED VIEW and SELECT INTO.
		 */
		rows = (qc && (qc->commandTag == CMDTAG_COPY ||
					   qc->commandTag == CMDTAG_FETCH ||
					   qc->commandTag == CMDTAG_SELECT ||
					   qc->commandTag == CMDTAG_REFRESH_MATERIALIZED_VIEW)) ?
			qc->nprocessed : 0;

		memset(&bufusage, 0, sizeof(BufferUsage));
		BufferUsageAccumDiff(&bufusage, &pgBufferUsage, &bufusage_start);
		memset(&walusage, 0, sizeof(WalUsage));
		WalUsageAccumDiff(&walusage, &pgWalUsage, &walusage_start);

		pgsr_accum(userid, false,
				   INSTR_TIME_GET_MILLISEC(duration),
				   rows,
				   &ru_start, &ru_stop,
				   &bufusage, &walusage);
	}
	else
	{
		nesting_level++;
		PG_TRY();
		{
			if (prev_ProcessUtility)
				prev_ProcessUtility(pstmt, queryString, readOnlyTree,
									context, params, queryEnv,
									dest, qc);
			else
				standard_ProcessUtility(pstmt, queryString, readOnlyTree,
										context, params, queryEnv,
										dest, qc);
		}
		PG_FINALLY();
		{
			nesting_level--;
		}
		PG_END_TRY();
	}
}

/*
 * object_access_hook: drop the stats entry when its role is dropped.
 *
 * The drop is registered transactionally, so the entry only goes away
 * if the surrounding transaction commits.  Entries that slip through
 * anyway can be mopped up with pg_stat_role_gc().
 */
static void
pgsr_object_access(ObjectAccessType access, Oid classId,
				   Oid objectId, int subId, void *arg)
{
	if (prev_object_access_hook)
		prev_object_access_hook(access, classId, objectId, subId, arg);

	if (access == OAT_DROP && classId == AuthIdRelationId && subId == 0)
		pgstat_drop_transactional(PGSTAT_KIND_ROLE, InvalidOid,
								  (uint64) objectId);
}

/*
 * Report an error if the module was not loaded via
 * shared_preload_libraries, in which case our stats kind is unknown to
 * the cumulative statistics machinery.
 */
static void
pgsr_check_loaded(void)
{
	if (!pgsr_kind_registered)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("pg_stat_role must be loaded via \"shared_preload_libraries\"")));
}

/*
 * SQL function: return one row per role statistics entry.
 */
Datum
pg_stat_role_entries(PG_FUNCTION_ARGS)
{
#define PG_STAT_ROLE_ENTRIES_COLS	22
	ReturnSetInfo *rsinfo;
	dshash_seq_status hstat;
	PgStatShared_HashEntry *p;

	pgsr_check_loaded();

	InitMaterializedSRF(fcinfo, 0);
	rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;

	/*
	 * Walk the shared statistics hash and copy out the entries of our
	 * kind, the same way pgstat_build_snapshot() does.
	 */
	dshash_seq_init(&hstat, pgStatLocal.shared_hash, false);
	while ((p = dshash_seq_next(&hstat)) != NULL)
	{
		PgStatShared_RoleEntry *shent;
		PgStat_StatRoleEntry stat;
		Datum		values[PG_STAT_ROLE_ENTRIES_COLS] = {0};
		bool		nulls[PG_STAT_ROLE_ENTRIES_COLS] = {0};
		int			i = 0;
		char		buf[32];

		if (p->key.kind != PGSTAT_KIND_ROLE || p->dropped)
			continue;

		shent = (PgStatShared_RoleEntry *)
			dsa_get_address(pgStatLocal.dsa, p->body);

		LWLockAcquire(&shent->header.lock, LW_SHARED);
		memcpy(&stat, &shent->stats, sizeof(stat));
		LWLockRelease(&shent->header.lock);

		values[i++] = ObjectIdGetDatum((Oid) p->key.objid);
		values[i++] = Int64GetDatum(stat.statements);
		values[i++] = Int64GetDatum(stat.rows);
		values[i++] = Float8GetDatum(stat.total_exec_time);
		values[i++] = Float8GetDatum(stat.cpu_user_time);
		values[i++] = Float8GetDatum(stat.cpu_system_time);
		values[i++] = Int64GetDatum(stat.vol_context_switches);
		values[i++] = Int64GetDatum(stat.invol_context_switches);
		values[i++] = Int64GetDatum(stat.shared_blks_hit);
		values[i++] = Int64GetDatum(stat.shared_blks_read);
		values[i++] = Int64GetDatum(stat.shared_blks_dirtied);
		values[i++] = Int64GetDatum(stat.shared_blks_written);
		values[i++] = Int64GetDatum(stat.local_blks_hit);
		values[i++] = Int64GetDatum(stat.local_blks_read);
		values[i++] = Int64GetDatum(stat.local_blks_dirtied);
		values[i++] = Int64GetDatum(stat.local_blks_written);
		values[i++] = Int64GetDatum(stat.temp_blks_read);
		values[i++] = Int64GetDatum(stat.temp_blks_written);
		values[i++] = Int64GetDatum(stat.wal_records);
		values[i++] = Int64GetDatum(stat.wal_fpi);

		/* convert uint64 wal_bytes through numeric */
		snprintf(buf, sizeof(buf), UINT64_FORMAT, stat.wal_bytes);
		values[i++] = DirectFunctionCall3(numeric_in,
										  CStringGetDatum(buf),
										  ObjectIdGetDatum(0),
										  Int32GetDatum(-1));

		if (stat.stat_reset_timestamp != 0)
			values[i++] = TimestampTzGetDatum(stat.stat_reset_timestamp);
		else
			nulls[i++] = true;

		Assert(i == PG_STAT_ROLE_ENTRIES_COLS);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc,
							 values, nulls);
	}
	dshash_seq_term(&hstat);

	return (Datum) 0;
}

/*
 * SQL function: reset statistics for one role, or for all roles if
 * called with NULL.
 */
Datum
pg_stat_role_reset(PG_FUNCTION_ARGS)
{
	pgsr_check_loaded();

	if (PG_ARGISNULL(0))
		pgstat_reset_of_kind(PGSTAT_KIND_ROLE);
	else
		pgstat_reset(PGSTAT_KIND_ROLE, InvalidOid,
					 (uint64) PG_GETARG_OID(0));

	PG_RETURN_VOID();
}

/*
 * SQL function: drop statistics entries whose role no longer exists in
 * pg_authid.  Returns the number of entries dropped.
 *
 * This is a safety net for entries that survived DROP ROLE, e.g. because
 * the extension was not loaded when the role was dropped.
 */
Datum
pg_stat_role_gc(PG_FUNCTION_ARGS)
{
	dshash_seq_status hstat;
	PgStatShared_HashEntry *p;
	Oid		   *roleids;
	int			nroleids = 0;
	int			maxroleids = 64;
	int64		ndropped = 0;

	pgsr_check_loaded();

	roleids = (Oid *) palloc(maxroleids * sizeof(Oid));

	/*
	 * Collect the role OIDs first; dropping entries while the sequential
	 * scan holds partition locks on the shared hash would be unsafe.
	 */
	dshash_seq_init(&hstat, pgStatLocal.shared_hash, false);
	while ((p = dshash_seq_next(&hstat)) != NULL)
	{
		if (p->key.kind != PGSTAT_KIND_ROLE || p->dropped)
			continue;

		if (nroleids >= maxroleids)
		{
			maxroleids *= 2;
			roleids = (Oid *) repalloc(roleids, maxroleids * sizeof(Oid));
		}
		roleids[nroleids++] = (Oid) p->key.objid;
	}
	dshash_seq_term(&hstat);

	for (int j = 0; j < nroleids; j++)
	{
		if (SearchSysCacheExists1(AUTHOID, ObjectIdGetDatum(roleids[j])))
			continue;

		if (!pgstat_drop_entry(PGSTAT_KIND_ROLE, InvalidOid,
							   (uint64) roleids[j], true))
			pgstat_request_entry_refs_gc();
		ndropped++;
	}

	pfree(roleids);

	PG_RETURN_INT64(ndropped);
}
