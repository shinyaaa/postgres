/*-------------------------------------------------------------------------
 *
 * subtrans.c
 *		PostgreSQL subtransaction-parent manager
 *
 * This module stores the parent transaction Id for each subtransaction.  It is
 * a fundamental part of the nested transactions implementation.  A main
 * transaction has a parent of InvalidTransactionId, and each subtransaction
 * has its immediate parent.  The tree can easily be walked from child to
 * parent, but not in the opposite direction.
 *
 * Historically this information was kept in an SLRU ("pg_subtrans"), modelled
 * on pg_xact.  However, unlike clog or multixact, subtrans data has very
 * different robustness requirements: we only ever need to remember the parent
 * of currently-running subtransactions, we never look back further than
 * TransactionXmin, and there is no need to preserve the data across a crash
 * and restart.  An on-disk, paged SLRU is therefore unnecessary overhead: it
 * forces I/O for mostly-zero pages and wastes buffer memory on transaction-id
 * ranges that never used a subtransaction at all.
 *
 * Instead we keep the subxid -> parent mapping in a partitioned shared-memory
 * hash table.  Entries are created on demand when a subtransaction first
 * records its parent, and removed in bulk by TruncateSUBTRANS() once they fall
 * behind the global xmin.  Because the table lives only in shared memory and
 * starts out empty, there are no XLOG interactions and nothing needs to be
 * reset at startup.
 *
 * Concurrency is handled exactly like the buffer mapping table: a fixed set of
 * partition locks, each protecting the buckets that hash to it.  Callers
 * compute the hash code once (get_hash_value), take the matching partition
 * lock, and then operate on the table with hash_search_with_hash_value().
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/backend/access/transam/subtrans.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/slru.h"
#include "access/subtrans.h"
#include "access/transam.h"
#include "miscadmin.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "utils/guc_hooks.h"
#include "utils/snapmgr.h"


/*
 * Number of partitions of the subtrans hash table.  Each partition has its
 * own LWLock.  Must be a power of two (see hash_create's HASH_PARTITION
 * handling).  Matched to NUM_BUFFER_PARTITIONS on the basis that whatever's
 * good enough for the buffer pool is good enough here.
 */
#define NUM_SUBTRANS_PARTITIONS 128

/*
 * For sizing purposes we keep treating the subtransaction_buffers GUC as a
 * number of SLRU-style "pages", each of which used to hold this many parent
 * pointers.  This preserves the historical meaning of the knob: a larger value
 * lets the hash table hold more concurrently-running subtransactions.
 */
#define SUBTRANS_XACTS_PER_PAGE (BLCKSZ / sizeof(TransactionId))

/* Hash table entry: maps a subtransaction xid to its immediate parent. */
typedef struct SubTransEntry
{
	TransactionId key;			/* subtransaction xid --- MUST BE FIRST */
	TransactionId parent;		/* immediate parent xid */
} SubTransEntry;

/* Shared control data: just the partition locks. */
typedef struct SubTransCtlData
{
	LWLockPadded partition_locks[NUM_SUBTRANS_PARTITIONS];
} SubTransCtlData;


static void SUBTRANSShmemRequest(void *arg);
static void SUBTRANSShmemInit(void *arg);
static int	SUBTRANSShmemBuffers(void);

const ShmemCallbacks SUBTRANSShmemCallbacks = {
	.request_fn = SUBTRANSShmemRequest,
	.init_fn = SUBTRANSShmemInit,
};

/*
 * Link to shared-memory data structures for SUBTRANS control.  Both pointers
 * are set by the shmem machinery (see SUBTRANSShmemRequest) before any
 * callback runs and on every (re)attach.
 */
static SubTransCtlData *SubTransCtl = NULL;
static HTAB *SubTransHash = NULL;

/*
 * Return the partition lock protecting the bucket for the given hash code.
 */
static inline LWLock *
SubTransPartitionLock(uint32 hashcode)
{
	return &SubTransCtl->partition_locks[hashcode % NUM_SUBTRANS_PARTITIONS].lock;
}


/*
 * Record the parent of a subtransaction.
 */
void
SubTransSetParent(TransactionId xid, TransactionId parent)
{
	uint32		hashcode;
	LWLock	   *lock;
	SubTransEntry *entry;
	bool		found;

	Assert(TransactionIdIsValid(parent));
	Assert(TransactionIdFollows(xid, parent));

	hashcode = get_hash_value(SubTransHash, &xid);
	lock = SubTransPartitionLock(hashcode);

	LWLockAcquire(lock, LW_EXCLUSIVE);

	entry = (SubTransEntry *) hash_search_with_hash_value(SubTransHash, &xid,
														  hashcode, HASH_ENTER,
														  &found);

	/*
	 * It's possible we'll try to set the parent xid multiple times but we
	 * shouldn't ever be changing the xid from one valid xid to another valid
	 * xid, which would corrupt the data structure.  A missing entry is
	 * equivalent to the old all-zeroes SLRU page.
	 */
	if (!found)
		entry->parent = parent;
	else
		Assert(entry->parent == parent);

	LWLockRelease(lock);
}

/*
 * Interrogate the parent of a transaction in the subtrans log.
 */
TransactionId
SubTransGetParent(TransactionId xid)
{
	uint32		hashcode;
	LWLock	   *lock;
	SubTransEntry *entry;
	TransactionId parent;

	/* Can't ask about stuff that might not be around anymore */
	Assert(TransactionIdFollowsOrEquals(xid, TransactionXmin));

	/* Bootstrap and frozen XIDs have no parent */
	if (!TransactionIdIsNormal(xid))
		return InvalidTransactionId;

	hashcode = get_hash_value(SubTransHash, &xid);
	lock = SubTransPartitionLock(hashcode);

	LWLockAcquire(lock, LW_SHARED);

	entry = (SubTransEntry *) hash_search_with_hash_value(SubTransHash, &xid,
														  hashcode, HASH_FIND,
														  NULL);

	/* A missing entry means no parent was ever recorded for this xid */
	parent = entry ? entry->parent : InvalidTransactionId;

	LWLockRelease(lock);

	return parent;
}

/*
 * SubTransGetTopmostTransaction
 *
 * Returns the topmost transaction of the given transaction id.
 *
 * Because we cannot look back further than TransactionXmin, it is possible
 * that this function will lie and return an intermediate subtransaction ID
 * instead of the true topmost parent ID.  This is OK, because in practice
 * we only care about detecting whether the topmost parent is still running
 * or is part of a current snapshot's list of still-running transactions.
 * Therefore, any XID before TransactionXmin is as good as any other.
 */
TransactionId
SubTransGetTopmostTransaction(TransactionId xid)
{
	TransactionId parentXid = xid,
				previousXid = xid;

	/* Can't ask about stuff that might not be around anymore */
	Assert(TransactionIdFollowsOrEquals(xid, TransactionXmin));

	while (TransactionIdIsValid(parentXid))
	{
		previousXid = parentXid;
		if (TransactionIdPrecedes(parentXid, TransactionXmin))
			break;
		parentXid = SubTransGetParent(parentXid);

		/*
		 * By convention the parent xid gets allocated first, so should always
		 * precede the child xid. Anything else points to a corrupted data
		 * structure that could lead to an infinite loop, so exit.
		 */
		if (!TransactionIdPrecedes(parentXid, previousXid))
			elog(ERROR, "pg_subtrans contains invalid entry: xid %u points to parent xid %u",
				 previousXid, parentXid);
	}

	Assert(TransactionIdIsValid(previousXid));

	return previousXid;
}

/*
 * Maximum number of subtransaction entries the hash table can hold.
 *
 * Derived from subtransaction_buffers (see the comment on
 * SUBTRANS_XACTS_PER_PAGE).  This is a hard cap: unlike the old SLRU, which
 * could spill to disk, the in-memory hash table cannot grow past the space
 * reserved here, so SubTransSetParent() will error if the cap is exceeded.
 * That is acceptable for now; a future revision could move to a growable
 * dshash to lift the limit entirely.
 */
static int64
SUBTRANSShmemEntries(void)
{
	return (int64) SUBTRANSShmemBuffers() * SUBTRANS_XACTS_PER_PAGE;
}

/*
 * Number of shared SUBTRANS buffers.
 *
 * If asked to autotune, use 2MB for every 1GB of shared buffers, up to 8MB.
 * Otherwise just cap the configured amount to be between 16 and the maximum
 * allowed.
 */
static int
SUBTRANSShmemBuffers(void)
{
	/* auto-tune based on shared buffers */
	if (subtransaction_buffers == 0)
		return SimpleLruAutotuneBuffers(512, 1024);

	return Min(Max(16, subtransaction_buffers), SLRU_MAX_ALLOWED_BUFFERS);
}

/*
 * Register shared memory for SUBTRANS
 */
static void
SUBTRANSShmemRequest(void *arg)
{
	/* If auto-tuning is requested, now is the time to do it */
	if (subtransaction_buffers == 0)
	{
		char		buf[32];

		snprintf(buf, sizeof(buf), "%d", SUBTRANSShmemBuffers());
		SetConfigOption("subtransaction_buffers", buf, PGC_POSTMASTER,
						PGC_S_DYNAMIC_DEFAULT);

		/*
		 * We prefer to report this value's source as PGC_S_DYNAMIC_DEFAULT.
		 * However, if the DBA explicitly set subtransaction_buffers = 0 in
		 * the config file, then PGC_S_DYNAMIC_DEFAULT will fail to override
		 * that and we must force the matter with PGC_S_OVERRIDE.
		 */
		if (subtransaction_buffers == 0)	/* failed to apply it? */
			SetConfigOption("subtransaction_buffers", buf, PGC_POSTMASTER,
							PGC_S_OVERRIDE);
	}
	Assert(subtransaction_buffers != 0);

	/* Partition locks live in this fixed-size control struct */
	ShmemRequestStruct(.name = "Subtrans Ctl",
					   .size = sizeof(SubTransCtlData),
					   .ptr = (void **) &SubTransCtl);

	/* The subxid -> parent mapping itself */
	ShmemRequestHash(.name = "Subtrans Hash",
					 .nelems = SUBTRANSShmemEntries(),
					 .ptr = &SubTransHash,
					 .hash_info.keysize = sizeof(TransactionId),
					 .hash_info.entrysize = sizeof(SubTransEntry),
					 .hash_info.num_partitions = NUM_SUBTRANS_PARTITIONS,
					 .hash_flags = HASH_ELEM | HASH_BLOBS | HASH_PARTITION | HASH_FIXED_SIZE,
		);
}

static void
SUBTRANSShmemInit(void *arg)
{
	/*
	 * Initialize the partition locks.  This runs once, at postmaster startup;
	 * the SubTransCtl/SubTransHash pointers themselves are set by the shmem
	 * machinery on every (re)attach.
	 */
	for (int i = 0; i < NUM_SUBTRANS_PARTITIONS; i++)
		LWLockInitialize(&SubTransCtl->partition_locks[i].lock,
						 LWTRANCHE_SUBTRANS_SLRU);
}

/*
 * GUC check_hook for subtransaction_buffers
 */
bool
check_subtrans_buffers(int *newval, void **extra, GucSource source)
{
	return check_slru_buffers("subtransaction_buffers", newval);
}

/*
 * This func must be called ONCE on system install.
 *
 * The subtrans hash table lives only in shared memory and starts out empty,
 * so there is nothing to create on disk.  The function is retained for symmetry
 * with the other transaction-log managers and in case callers expect it.
 */
void
BootStrapSUBTRANS(void)
{
	/* Nothing to do */
}

/*
 * This must be called ONCE during postmaster or standalone-backend startup,
 * after StartupXLOG has initialized TransamVariables->nextXid.
 *
 * The hash table starts out empty in freshly-allocated shared memory, which is
 * exactly the state we want (equivalent to the old all-zeroes SLRU pages).
 * Any parent information for transactions that were running at the time of a
 * crash is re-established during recovery (see ProcArrayApplyXidAssignment and
 * the two-phase commit recovery path), so there is nothing to initialize here.
 */
void
StartupSUBTRANS(TransactionId oldestActiveXID)
{
	/* Nothing to do */
}

/*
 * Perform a checkpoint --- either during shutdown, or on-the-fly
 *
 * There is no persistent state to flush, so this is a no-op.
 */
void
CheckPointSUBTRANS(void)
{
	/* Nothing to do */
}

/*
 * Make sure that SUBTRANS has room for a newly-allocated XID.
 *
 * Entries are allocated on demand by SubTransSetParent(), so there is nothing
 * to pre-extend.  Retained as a no-op because GetNewTransactionId() and the
 * recovery code call it unconditionally.
 */
void
ExtendSUBTRANS(TransactionId newestXact)
{
	/* Nothing to do */
}

/*
 * Remove all SUBTRANS entries for transactions preceding the passed xid.
 *
 * oldestXact is the oldest TransactionXmin of any running transaction.  This
 * is called only during checkpoint and startup.  Anything older than that can
 * never be looked up again (SubTransGetParent/Topmost never go further back
 * than TransactionXmin), so it is safe to drop.
 */
void
TruncateSUBTRANS(TransactionId oldestXact)
{
	HASH_SEQ_STATUS status;
	SubTransEntry *entry;

	/*
	 * Lock out all concurrent access while we prune.  This is heavy-handed,
	 * but truncation is infrequent (checkpoint/startup) whereas the common
	 * set/get paths only ever take a single partition lock.
	 */
	for (int i = 0; i < NUM_SUBTRANS_PARTITIONS; i++)
		LWLockAcquire(&SubTransCtl->partition_locks[i].lock, LW_EXCLUSIVE);

	hash_seq_init(&status, SubTransHash);
	while ((entry = (SubTransEntry *) hash_seq_search(&status)) != NULL)
	{
		if (TransactionIdPrecedes(entry->key, oldestXact))
			(void) hash_search(SubTransHash, &entry->key, HASH_REMOVE, NULL);
	}

	for (int i = NUM_SUBTRANS_PARTITIONS - 1; i >= 0; i--)
		LWLockRelease(&SubTransCtl->partition_locks[i].lock);
}
