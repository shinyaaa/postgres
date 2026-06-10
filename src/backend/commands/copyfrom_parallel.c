/*-------------------------------------------------------------------------
 *
 * copyfrom_parallel.c
 *	  Parallel COPY FROM.
 *
 * A parallel COPY FROM divides the input file into byte ranges that start
 * at line boundaries (see copyfrom_linescan.c) and lets each participating
 * process load one range using the regular COPY FROM machinery, bounded by
 * cstate->raw_bytes_limit.  The leader hands ranges 0 .. N-2 to N-1
 * workers and processes the final range itself while waiting; the worker
 * processing the start of the file also handles any header line.  If fewer
 * workers than planned can be launched, the unowned ranges are contiguous
 * with the leader's, which simply takes them over; with no workers at all,
 * the COPY degrades to a plain serial one.
 *
 * There is no data transfer between the processes: each one opens the
 * input file itself and seeks to its assigned range.  The dynamic shared
 * memory segment carries only the metadata needed to reconstruct an
 * equivalent CopyFromState in each worker, and an atomic counter
 * aggregating the number of processed rows.
 *
 * All participants insert tuples with the XID and command ID of the
 * leader's transaction, which the parallel infrastructure serializes for
 * us; the leader assigns its XID and marks the command ID as used before
 * entering parallel mode.  Whether an operation is eligible for
 * parallelism is decided by ParallelCopyFromPlanWorkers(); anything it
 * cannot prove safe falls back to serial execution.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * IDENTIFICATION
 *	  src/backend/commands/copyfrom_parallel.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <sys/stat.h>

#include "access/parallel.h"
#include "access/table.h"
#include "access/xact.h"
#include "catalog/pg_am_d.h"
#include "catalog/pg_attribute.h"
#include "commands/copyfrom_internal.h"
#include "commands/copyfrom_parallel.h"
#include "executor/executor.h"
#include "executor/instrument.h"
#include "miscadmin.h"
#include "optimizer/clauses.h"
#include "parser/parse_node.h"
#include "parser/parse_relation.h"
#include "pgstat.h"
#include "port/atomics.h"
#include "rewrite/rewriteHandler.h"
#include "storage/fd.h"
#include "tcop/tcopprot.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"

/* DSM keys for parallel COPY FROM */
#define PARALLEL_COPY_KEY_SHARED		1
#define PARALLEL_COPY_KEY_FILENAME		2
#define PARALLEL_COPY_KEY_OPTIONS		3
#define PARALLEL_COPY_KEY_ATTNAMELIST	4
#define PARALLEL_COPY_KEY_WAL_USAGE		5
#define PARALLEL_COPY_KEY_BUFFER_USAGE	6
#define PARALLEL_COPY_KEY_QUERY_TEXT	7

/*
 * There is no point in distributing tiny files; each participant should
 * get at least this many bytes of input to chew on.
 */
#define MIN_PARALLEL_COPY_RANGE_SIZE	(64 * 1024)

/* Shared state for a parallel COPY FROM */
typedef struct ParallelCopyShared
{
	Oid			relid;			/* target relation */
	int			nranges;		/* number of byte ranges planned */
	int64		file_size;		/* input file size at planning time */
	EolType		eol_type;		/* newline style of the input file */
	pg_atomic_uint64 nprocessed;	/* rows inserted by the workers */
	int64		offsets[FLEXIBLE_ARRAY_MEMBER]; /* nranges + 1 range bounds */
} ParallelCopyShared;

/* Argument for ParallelCopyFromRangeCallback */
typedef struct ParallelCopyRangeInfo
{
	const char *filename;
	int64		range_start;
} ParallelCopyRangeInfo;

/* Leader-side state of a parallel COPY FROM */
struct ParallelCopyFromState
{
	ParallelContext *pcxt;
	ParallelCopyShared *shared;
	WalUsage   *wal_usage;		/* per-worker WAL usage, in DSM */
	BufferUsage *buffer_usage;	/* per-worker buffer usage, in DSM */
	ParallelCopyRangeInfo rangeinfo;
	ErrorContextCallback errcallback;
};

static int	ParallelCopyFromPlanWorkers(CopyFromState cstate,
										CopyInsertMethod insertMethod,
										ResultRelInfo *resultRelInfo,
										int64 *file_size_out);
static void ParallelCopyFromCheckRangeDone(CopyFromState cstate,
										   bool is_last_range);
static void ParallelCopyFromRangeCallback(void *arg);

/*
 * Note the reason for not running a requested parallel COPY FROM in
 * parallel, and tell the caller to proceed serially.  Falling back is
 * silent at the default message level, like an unsatisfiable parallel
 * query plan.
 */
static int
parallel_copy_not_used(const char *reason)
{
	ereport(DEBUG1,
			(errmsg_internal("parallel COPY FROM not used: %s", reason)));
	return 0;
}

/*
 * Decide whether this COPY FROM can run in parallel, and with how many
 * workers.  Returns 0 if it cannot; the caller then proceeds serially.
 *
 * The checks are deliberately structured as a default-deny list: anything
 * that cannot be proven safe disables parallelism.  The fundamental
 * restrictions of the design are that every participant must be able to
 * parse its byte range independently (hence: a seekable plain file, text
 * format, no encoding conversion, at most one header line) and that
 * workers insert tuples under the leader's XID and command ID without any
 * ability to start commands, queue trigger events, or evaluate
 * parallel-unsafe expressions.
 */
static int
ParallelCopyFromPlanWorkers(CopyFromState cstate,
							CopyInsertMethod insertMethod,
							ResultRelInfo *resultRelInfo,
							int64 *file_size_out)
{
	Relation	rel = cstate->rel;
	TupleDesc	tupDesc = RelationGetDescr(rel);
	struct stat st;
	int64		file_size;
	int			nworkers;

	/*
	 * The input must be a seekable regular file that every worker can open
	 * independently.  This excludes STDIN, PROGRAM pipes and data source
	 * callbacks.
	 */
	if (cstate->copy_src != COPY_FILE ||
		cstate->filename == NULL ||
		cstate->is_program)
		return parallel_copy_not_used("input is not a server-side file");

	if (fstat(fileno(cstate->copy_file), &st) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not stat file \"%s\": %m", cstate->filename)));
	if (!S_ISREG(st.st_mode))
		return parallel_copy_not_used("input is not a regular file");
	file_size = (int64) st.st_size;

	/*
	 * Only text format: fixed-size binary framing and CSV quoted fields
	 * cannot be split at line boundaries found by a forward byte scan.
	 */
	if (cstate->opts.format != COPY_FORMAT_TEXT)
		return parallel_copy_not_used("only text format is supported");

	/*
	 * The line scanner works on raw bytes, which is only safe when no
	 * encoding conversion is required (all server encodings are ASCII-safe).
	 */
	if (cstate->need_transcoding)
		return parallel_copy_not_used("encoding conversion is required");

	/* Multi-line headers could spill beyond the first byte range. */
	if (cstate->opts.header_line > 1)
		return parallel_copy_not_used("multi-line header is not supported");

	/*
	 * WHERE clauses and the soft error modes of ON_ERROR have side effects
	 * (excluded-row accounting, error limits, NOTICEs) that we make no
	 * attempt to coordinate across processes.
	 */
	if (cstate->whereClause != NULL)
		return parallel_copy_not_used("WHERE clause is not supported");
	if (cstate->opts.on_error != COPY_ON_ERROR_STOP)
		return parallel_copy_not_used("ON_ERROR mode is not supported");

	/*
	 * FREEZE requires the relation to be created or truncated in the
	 * current subtransaction, and we exclude such relations below anyway.
	 */
	if (cstate->opts.freeze)
		return parallel_copy_not_used("FREEZE is not supported");

	/*
	 * Require the plain multi-insert path.  This already excludes
	 * partitioned tables, foreign tables, before/instead row triggers and
	 * volatile default expressions, but we recheck the essentials below
	 * rather than depend on how the insert method was derived.
	 */
	if (insertMethod != CIM_MULTI)
		return parallel_copy_not_used("multi-insert cannot be used");

	/*
	 * No INSERT triggers of any kind.  Workers cannot queue after-trigger
	 * events (this includes foreign key checks and deferred unique
	 * constraints, which are implemented as such), and excluding statement
	 * triggers keeps the command ID of the operation stable.
	 */
	if (resultRelInfo->ri_TrigDesc != NULL &&
		(resultRelInfo->ri_TrigDesc->trig_insert_before_row ||
		 resultRelInfo->ri_TrigDesc->trig_insert_after_row ||
		 resultRelInfo->ri_TrigDesc->trig_insert_instead_row ||
		 resultRelInfo->ri_TrigDesc->trig_insert_before_statement ||
		 resultRelInfo->ri_TrigDesc->trig_insert_after_statement ||
		 resultRelInfo->ri_TrigDesc->trig_insert_new_table))
		return parallel_copy_not_used("table has INSERT triggers");

	/*
	 * Plain heap tables only.  Parallel inserts have been vetted for the
	 * heap AM (see heap_prepare_insert); other table AMs would need their
	 * own analysis.
	 */
	if (rel->rd_rel->relkind != RELKIND_RELATION)
		return parallel_copy_not_used("target is not a plain table");
	if (rel->rd_rel->relam != HEAP_TABLE_AM_OID)
		return parallel_copy_not_used("target does not use the heap access method");

	/* Temporary tables cannot be accessed by parallel workers. */
	if (RelationUsesLocalBuffers(rel))
		return parallel_copy_not_used("target is a temporary table");

	/*
	 * Relations created or rewritten in the current (sub)transaction use
	 * optimizations (FSM skipping, pending syncs) that we'd rather not
	 * reason about across processes.
	 */
	if (rel->rd_createSubid != InvalidSubTransactionId ||
		rel->rd_firstRelfilelocatorSubid != InvalidSubTransactionId)
		return parallel_copy_not_used("target is new in the current transaction");

	/*
	 * Per-column checks: no domain types (domain constraints are evaluated
	 * by input functions and are treated as parallel-restricted in query
	 * planning, too), and any default or generation expression that will
	 * be evaluated must be parallel safe.  Note that nextval() is parallel
	 * unsafe, so tables with serial/identity columns not supplied by the
	 * input fall back to serial COPY.
	 */
	for (int attnum = 1; attnum <= tupDesc->natts; attnum++)
	{
		Form_pg_attribute att = TupleDescAttr(tupDesc, attnum - 1);

		if (att->attisdropped)
			continue;

		if (get_typtype(att->atttypid) == TYPTYPE_DOMAIN)
			return parallel_copy_not_used("a column is of a domain type");

		if (att->attgenerated == ATTRIBUTE_GENERATED_STORED)
		{
			Node	   *gexpr = build_generation_expression(rel, attnum);

			if (!expr_is_parallel_safe(gexpr))
				return parallel_copy_not_used("a generation expression is not parallel safe");
			continue;
		}
		else if (att->attgenerated)
			continue;			/* virtual generated columns are not stored */

		if (cstate->opts.default_print != NULL ||
			!list_member_int(cstate->attnumlist, attnum))
		{
			Node	   *defexpr = build_column_default(rel, attnum);

			if (defexpr != NULL && !expr_is_parallel_safe(defexpr))
				return parallel_copy_not_used("a default expression is not parallel safe");
		}
	}

	/* CHECK constraints must be parallel safe. */
	if (tupDesc->constr != NULL)
	{
		TupleConstr *constr = tupDesc->constr;

		for (int i = 0; i < constr->num_check; i++)
		{
			Node	   *checkexpr = stringToNode(constr->check[i].ccbin);

			if (!expr_is_parallel_safe(checkexpr))
				return parallel_copy_not_used("a CHECK constraint is not parallel safe");
		}
	}

	/*
	 * Index expressions and predicates must be parallel safe, and we do
	 * not support exclusion constraints, whose recheck mechanism has not
	 * been vetted for parallel workers.
	 */
	for (int i = 0; i < resultRelInfo->ri_NumIndices; i++)
	{
		IndexInfo  *ii = resultRelInfo->ri_IndexRelationInfo[i];

		if (ii->ii_ExclusionOps != NULL)
			return parallel_copy_not_used("table has an exclusion constraint");
		if (ii->ii_Expressions != NIL &&
			!expr_is_parallel_safe((Node *) ii->ii_Expressions))
			return parallel_copy_not_used("an index expression is not parallel safe");
		if (ii->ii_Predicate != NIL &&
			!expr_is_parallel_safe((Node *) ii->ii_Predicate))
			return parallel_copy_not_used("an index predicate is not parallel safe");
	}

	/*
	 * Looks good.  Cap the worker count so that each participant
	 * (including the leader) gets a reasonable amount of input.
	 */
	nworkers = Min((int64) cstate->opts.parallel,
				   file_size / MIN_PARALLEL_COPY_RANGE_SIZE - 1);
	if (nworkers < 1)
		return parallel_copy_not_used("input file is too small");

	*file_size_out = file_size;
	return nworkers;
}

/*
 * Error context callback identifying the byte range a participant of a
 * parallel COPY FROM was processing.  Line numbers reported by
 * CopyFromErrorCallback() are relative to the start of the range, so this
 * additional line is what makes them locatable in the file.
 */
static void
ParallelCopyFromRangeCallback(void *arg)
{
	ParallelCopyRangeInfo *info = (ParallelCopyRangeInfo *) arg;

	errcontext("parallel COPY FROM byte range of file \"%s\" starting at offset %" PRId64,
			   info->filename, info->range_start);
}

/*
 * Verify that this participant consumed its byte range completely.
 *
 * An end-of-copy marker (\.) at the very end of the file behaves exactly
 * as in a serial COPY: it just terminates the input.  A marker anywhere
 * else is an error: in a non-final range, other participants have
 * processed input that a serial COPY would have ignored; and although a
 * marker within the final range would actually produce the serial result,
 * accepting it there would make the outcome depend on how many workers
 * were launched, so we reject that too, for predictability.
 */
static void
ParallelCopyFromCheckRangeDone(CopyFromState cstate, bool is_last_range)
{
	if (cstate->eocm_found)
	{
		/* without transcoding, raw_buf and input_buf are the same buffer */
		Assert(cstate->raw_buf == cstate->input_buf);

		if (is_last_range &&
			cstate->raw_bytes_read >= cstate->raw_bytes_limit &&
			cstate->input_buf_index == cstate->raw_buf_len)
			return;
		ereport(ERROR,
				(errcode(ERRCODE_BAD_COPY_FILE_FORMAT),
				 errmsg("end-of-copy marker was found in the middle of file \"%s\"",
						cstate->filename),
				 errdetail("COPY FROM stops at an end-of-copy marker, but parallel processes may have processed input beyond it."),
				 errhint("Run COPY FROM without the PARALLEL option.")));
	}

	/*
	 * Otherwise the parser must have consumed the assigned byte range
	 * exactly; reading fewer bytes means the file shrank while we were
	 * reading it.
	 */
	if (cstate->raw_bytes_read < cstate->raw_bytes_limit)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("could not read the assigned byte range of file \"%s\"",
						cstate->filename),
				 errdetail("The file was modified while it was being copied.")));
}

/*
 * Begin a parallel COPY FROM: plan the byte ranges, launch workers, and
 * configure the leader's cstate to process the trailing range.
 *
 * Returns NULL if the operation is not eligible, the input cannot be
 * usefully split, or no workers could be launched; the caller then
 * proceeds with a plain serial COPY.
 */
ParallelCopyFromState *
BeginParallelCopyFrom(CopyFromState cstate, CopyInsertMethod insertMethod,
					  ResultRelInfo *resultRelInfo)
{
	ParallelCopyFromState *pcstate;
	ParallelCopyShared *shared;
	ParallelContext *pcxt;
	EolType		eol_type;
	int64		file_size = 0;
	int64	   *offsets;
	int			nworkers;
	int			nranges;
	int			nlaunched;
	char	   *optionsstr;
	char	   *attnamesstr;
	char	   *sharedptr;
	WalUsage   *wal_usage;
	BufferUsage *buffer_usage;
	const char *querytext = debug_query_string;
	Size		sharedlen;

	Assert(!IsParallelWorker());
	Assert(cstate->opts.parallel > 0);

	nworkers = ParallelCopyFromPlanWorkers(cstate, insertMethod,
										   resultRelInfo, &file_size);
	if (nworkers <= 0)
		return NULL;

	/* The leader participates too, so plan one extra range. */
	nranges = nworkers + 1;

	/*
	 * Determine the newline style and divide the file into ranges starting
	 * at line boundaries.  These scans move the file position; we seek to
	 * our own range (or back to the beginning, on failure) afterwards.
	 */
	eol_type = ParallelCopyDetectEol(cstate->copy_file, file_size);

	offsets = NULL;
	if (eol_type != EOL_UNKNOWN)
	{
		offsets = palloc_array(int64, nranges + 1);
		nranges = ParallelCopyFindSplitPoints(cstate->copy_file, file_size,
											  eol_type, nranges, offsets);
	}

	if (eol_type == EOL_UNKNOWN || nranges < 2)
	{
		/* a single line, or lines too long to find enough split points */
		if (fseeko(cstate->copy_file, 0, SEEK_SET) != 0)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not rewind file \"%s\": %m",
							cstate->filename)));
		if (offsets)
			pfree(offsets);
		(void) parallel_copy_not_used("not enough line boundaries in the input file");
		return NULL;
	}

	/*
	 * Make sure our transaction has an XID and that the current command ID
	 * is marked as used, before the parallel infrastructure serializes
	 * them: the workers insert tuples with both.  (CopyFrom() has already
	 * fetched the command ID with used = true; the XID assignment must
	 * happen before entering parallel mode.)
	 */
	(void) GetCurrentTransactionId();
	(void) GetCurrentCommandId(true);

	EnterParallelMode();

	/* Declare that our workers will write data; serialized into the DSM */
	EnableParallelDML();

	pcxt = CreateParallelContext("postgres", "ParallelCopyFromWorkerMain",
								 nranges - 1);

	/* Estimate space for all the DSM entries we need */
	sharedlen = add_size(offsetof(ParallelCopyShared, offsets),
						 mul_size(sizeof(int64), nranges + 1));
	shm_toc_estimate_chunk(&pcxt->estimator, sharedlen);
	shm_toc_estimate_keys(&pcxt->estimator, 1);

	shm_toc_estimate_chunk(&pcxt->estimator, strlen(cstate->filename) + 1);
	shm_toc_estimate_keys(&pcxt->estimator, 1);

	optionsstr = nodeToString(cstate->raw_options);
	shm_toc_estimate_chunk(&pcxt->estimator, strlen(optionsstr) + 1);
	shm_toc_estimate_keys(&pcxt->estimator, 1);

	attnamesstr = nodeToString(cstate->raw_attnamelist);
	shm_toc_estimate_chunk(&pcxt->estimator, strlen(attnamesstr) + 1);
	shm_toc_estimate_keys(&pcxt->estimator, 1);

	shm_toc_estimate_chunk(&pcxt->estimator,
						   mul_size(sizeof(WalUsage), pcxt->nworkers));
	shm_toc_estimate_keys(&pcxt->estimator, 1);
	shm_toc_estimate_chunk(&pcxt->estimator,
						   mul_size(sizeof(BufferUsage), pcxt->nworkers));
	shm_toc_estimate_keys(&pcxt->estimator, 1);

	if (querytext)
	{
		shm_toc_estimate_chunk(&pcxt->estimator, strlen(querytext) + 1);
		shm_toc_estimate_keys(&pcxt->estimator, 1);
	}

	InitializeParallelDSM(pcxt);

	/* Fill in the shared state */
	shared = (ParallelCopyShared *) shm_toc_allocate(pcxt->toc, sharedlen);
	shared->relid = RelationGetRelid(cstate->rel);
	shared->nranges = nranges;
	shared->file_size = file_size;
	shared->eol_type = eol_type;
	pg_atomic_init_u64(&shared->nprocessed, 0);
	memcpy(shared->offsets, offsets, sizeof(int64) * (nranges + 1));
	shm_toc_insert(pcxt->toc, PARALLEL_COPY_KEY_SHARED, shared);

	sharedptr = (char *) shm_toc_allocate(pcxt->toc,
										  strlen(cstate->filename) + 1);
	strcpy(sharedptr, cstate->filename);
	shm_toc_insert(pcxt->toc, PARALLEL_COPY_KEY_FILENAME, sharedptr);

	sharedptr = (char *) shm_toc_allocate(pcxt->toc, strlen(optionsstr) + 1);
	strcpy(sharedptr, optionsstr);
	shm_toc_insert(pcxt->toc, PARALLEL_COPY_KEY_OPTIONS, sharedptr);

	sharedptr = (char *) shm_toc_allocate(pcxt->toc, strlen(attnamesstr) + 1);
	strcpy(sharedptr, attnamesstr);
	shm_toc_insert(pcxt->toc, PARALLEL_COPY_KEY_ATTNAMELIST, sharedptr);

	wal_usage = shm_toc_allocate(pcxt->toc,
								 mul_size(sizeof(WalUsage), pcxt->nworkers));
	shm_toc_insert(pcxt->toc, PARALLEL_COPY_KEY_WAL_USAGE, wal_usage);
	buffer_usage = shm_toc_allocate(pcxt->toc,
									mul_size(sizeof(BufferUsage), pcxt->nworkers));
	shm_toc_insert(pcxt->toc, PARALLEL_COPY_KEY_BUFFER_USAGE, buffer_usage);

	if (querytext)
	{
		sharedptr = (char *) shm_toc_allocate(pcxt->toc,
											  strlen(querytext) + 1);
		strcpy(sharedptr, querytext);
		shm_toc_insert(pcxt->toc, PARALLEL_COPY_KEY_QUERY_TEXT, sharedptr);
	}

	LaunchParallelWorkers(pcxt);
	nlaunched = pcxt->nworkers_launched;

	if (nlaunched == 0)
	{
		/* Could not launch anything: degrade to a plain serial COPY. */
		DestroyParallelContext(pcxt);
		ExitParallelMode();
		if (fseeko(cstate->copy_file, 0, SEEK_SET) != 0)
			ereport(ERROR,
					(errcode_for_file_access(),
					 errmsg("could not rewind file \"%s\": %m",
							cstate->filename)));
		pfree(offsets);
		(void) parallel_copy_not_used("no parallel workers could be launched");
		return NULL;
	}

	/*
	 * Configure ourselves to process the trailing range.  If fewer workers
	 * than planned were launched, the unowned ranges nlaunched .. nranges-1
	 * are contiguous, so we simply take them all.
	 */
	if (fseeko(cstate->copy_file, offsets[nlaunched], SEEK_SET) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not seek in file \"%s\": %m",
						cstate->filename)));
	cstate->raw_bytes_limit = file_size - offsets[nlaunched];
	cstate->eol_type = eol_type;
	cstate->is_parallel = true;

	/* The worker processing the start of the file owns any header line. */
	cstate->opts.header_line = COPY_HEADER_FALSE;

	pcstate = palloc0_object(ParallelCopyFromState);
	pcstate->pcxt = pcxt;
	pcstate->shared = shared;
	pcstate->wal_usage = wal_usage;
	pcstate->buffer_usage = buffer_usage;

	/* Identify our byte range in any error context report */
	pcstate->rangeinfo.filename = cstate->filename;
	pcstate->rangeinfo.range_start = offsets[nlaunched];
	pcstate->errcallback.callback = ParallelCopyFromRangeCallback;
	pcstate->errcallback.arg = &pcstate->rangeinfo;
	pcstate->errcallback.previous = error_context_stack;
	error_context_stack = &pcstate->errcallback;

	pfree(offsets);

	return pcstate;
}

/*
 * Finish a parallel COPY FROM in the leader: verify our own range, wait
 * for the workers, and return the number of rows they inserted.
 */
uint64
EndParallelCopyFrom(CopyFromState cstate, ParallelCopyFromState *pcstate)
{
	uint64		nprocessed;

	/* Pop our range error context callback */
	error_context_stack = pcstate->errcallback.previous;

	/* The leader always owns the final range. */
	ParallelCopyFromCheckRangeDone(cstate, true);

	WaitForParallelWorkersToFinish(pcstate->pcxt);

	for (int i = 0; i < pcstate->pcxt->nworkers_launched; i++)
		InstrAccumParallelQuery(&pcstate->buffer_usage[i],
								&pcstate->wal_usage[i]);

	nprocessed = pg_atomic_read_u64(&pcstate->shared->nprocessed);

	DestroyParallelContext(pcstate->pcxt);
	ExitParallelMode();
	pfree(pcstate);

	return nprocessed;
}

/*
 * Parallel COPY FROM worker entry point.
 *
 * Reconstructs a CopyFromState equivalent to the leader's, confined to
 * this worker's byte range, and runs the regular CopyFrom() on it.  The
 * transaction environment (XID, command ID, snapshot, ...) has already
 * been set up by the parallel worker infrastructure.
 */
void
ParallelCopyFromWorkerMain(dsm_segment *seg, shm_toc *toc)
{
	ParallelCopyShared *shared;
	char	   *filename;
	char	   *optionsstr;
	char	   *attnamesstr;
	char	   *querytext;
	WalUsage   *wal_usage;
	BufferUsage *buffer_usage;
	List	   *options;
	List	   *attnamelist;
	Relation	rel;
	ParseState *pstate;
	ParseNamespaceItem *nsitem;
	RTEPermissionInfo *perminfo;
	CopyFromState cstate;
	ParallelCopyRangeInfo rangeinfo;
	ErrorContextCallback errcallback;
	int64		range_start;
	int64		range_end;
	uint64		nprocessed;
	struct stat st;

	shared = (ParallelCopyShared *) shm_toc_lookup(toc,
												   PARALLEL_COPY_KEY_SHARED,
												   false);
	filename = (char *) shm_toc_lookup(toc, PARALLEL_COPY_KEY_FILENAME,
									   false);
	optionsstr = (char *) shm_toc_lookup(toc, PARALLEL_COPY_KEY_OPTIONS,
										 false);
	attnamesstr = (char *) shm_toc_lookup(toc, PARALLEL_COPY_KEY_ATTNAMELIST,
										  false);
	querytext = (char *) shm_toc_lookup(toc, PARALLEL_COPY_KEY_QUERY_TEXT,
										true);

	/* Set debug_query_string for individual workers */
	debug_query_string = querytext;
	pgstat_report_activity(STATE_RUNNING, debug_query_string);

	Assert(ParallelWorkerNumber >= 0 &&
		   ParallelWorkerNumber < shared->nranges - 1);
	range_start = shared->offsets[ParallelWorkerNumber];
	range_end = shared->offsets[ParallelWorkerNumber + 1];

	options = (List *) stringToNode(optionsstr);
	attnamelist = (List *) stringToNode(attnamesstr);

	/*
	 * Open the target relation.  We are a member of the leader's lock
	 * group, so this cannot block on the leader's own lock.
	 */
	rel = table_open(shared->relid, RowExclusiveLock);

	/*
	 * Build the same single-entry range table that DoCopy() builds in the
	 * leader, which CopyFrom() requires.  The leader has already performed
	 * the permission checks.
	 */
	pstate = make_parsestate(NULL);
	pstate->p_sourcetext = querytext;
	nsitem = addRangeTableEntryForRelation(pstate, rel, RowExclusiveLock,
										   NULL, false, false);
	perminfo = nsitem->p_perminfo;
	perminfo->requiredPerms = ACL_INSERT;

	cstate = BeginCopyFrom(pstate, rel, NULL /* whereClause */ , filename,
						   false /* is_program */ , NULL /* data_source_cb */ ,
						   attnamelist, options);

	/* The input file must not have changed since the leader examined it */
	if (fstat(fileno(cstate->copy_file), &st) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not stat file \"%s\": %m", filename)));
	if ((int64) st.st_size != shared->file_size)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("file \"%s\" was modified during parallel COPY FROM",
						filename)));

	/* Confine this worker to its assigned byte range */
	if (fseeko(cstate->copy_file, range_start, SEEK_SET) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not seek in file \"%s\": %m", filename)));
	cstate->raw_bytes_limit = range_end - range_start;
	cstate->eol_type = shared->eol_type;
	cstate->is_parallel = true;

	/* Only the worker processing the start of the file handles the header */
	if (range_start > 0)
		cstate->opts.header_line = COPY_HEADER_FALSE;

	/* Identify our byte range in any error context report */
	rangeinfo.filename = cstate->filename;
	rangeinfo.range_start = range_start;
	errcallback.callback = ParallelCopyFromRangeCallback;
	errcallback.arg = &rangeinfo;
	errcallback.previous = error_context_stack;
	error_context_stack = &errcallback;

	/* Track buffer and WAL usage, to be reported back to the leader */
	InstrStartParallelQuery();

	nprocessed = CopyFrom(cstate);

	ParallelCopyFromCheckRangeDone(cstate, false);

	/* Report buffer and WAL usage during parallel execution */
	wal_usage = (WalUsage *) shm_toc_lookup(toc, PARALLEL_COPY_KEY_WAL_USAGE,
											false);
	buffer_usage = (BufferUsage *) shm_toc_lookup(toc,
												  PARALLEL_COPY_KEY_BUFFER_USAGE,
												  false);
	InstrEndParallelQuery(&buffer_usage[ParallelWorkerNumber],
						  &wal_usage[ParallelWorkerNumber]);

	pg_atomic_fetch_add_u64(&shared->nprocessed, nprocessed);

	error_context_stack = errcallback.previous;

	EndCopyFrom(cstate);
	table_close(rel, NoLock);
}
