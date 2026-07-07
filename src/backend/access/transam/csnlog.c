/*-------------------------------------------------------------------------
 *
 * csnlog.c
 *		PostgreSQL commit-sequence-number log manager
 *
 * The pg_csnlog manager is a pg_xact-like manager that stores, for every
 * transaction ID (including subtransaction IDs), the commit sequence
 * number (CSN) of the transaction tree it belongs to.  On a primary, the
 * CSN is assigned from a monotonic counter (TransamVariables->
 * lastCommitSeqNo) at the moment the transaction is removed from the set
 * of running transactions, under ProcArrayLock; the CSN order is therefore
 * by construction the order in which transactions became visible.  (The
 * commit record's LSN cannot be used directly: WAL insertion order and
 * visibility-publication order can differ when a committer stalls between
 * the two, and a CSN must never be ordered before a snapshot that did not
 * see the transaction as committed.)  During recovery, commit records are
 * replayed - and hence published - in WAL order, so there the commit
 * record's end LSN is used as the CSN; the counter is seeded from an LSN
 * at startup and caught up to end-of-WAL at promotion, which keeps the two
 * value ranges mutually monotonic.
 *
 * The CSN log is the basis of CSN snapshots: a snapshot is essentially
 * just a single CSN, and an XID is visible to it iff the XID's CSN is
 * valid and <= the snapshot's CSN.  Because all subtransactions receive
 * the same CSN as their top-level transaction at commit, visibility
 * checks never need to map a subtransaction to its parent; this is what
 * removes pg_subtrans from the tuple-visibility hot path.
 *
 * Entries can hold a few special values (see access/transam.h):
 *	 InvalidCommitSeqNo	- transaction in progress (or crashed)
 *	 CSN_ABORTED		- transaction (or subtransaction) aborted
 *	 CSN_COMMITTING		- transaction tree is between being assigned its
 *						  CSN and having the value stamped here; readers
 *						  must wait and retry (CSNLogGetCommitSeqNoWait)
 *	 CSN_FROZEN			- committed before this standby started recovery;
 *						  visible to every snapshot
 *
 * Like pg_subtrans, pg_csnlog does not need to survive a crash: after
 * crash recovery on a primary there are no running transactions, so every
 * pre-crash XID falls below the xmin of any future snapshot and its entry
 * is never consulted.  During recovery the log is reconstructed by
 * stamping entries as commit/abort records are replayed; entries covering
 * transactions that completed before the WAL replay window are seeded
 * from pg_xact at startup (see StartupCSNLOG).  Hence there are no XLOG
 * records for this module.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/backend/access/transam/csnlog.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/csnlog.h"
#include "access/slru.h"
#include "access/transam.h"
#include "miscadmin.h"
#include "storage/s_lock.h"
#include "storage/subsystems.h"


/*
 * Defines for CSNLOG page sizes.  A page is the same BLCKSZ as is used
 * everywhere else in Postgres.
 *
 * Note: because TransactionIds are 32 bits and wrap around at 0xFFFFFFFF,
 * CSNLOG page numbering also wraps around at
 * 0xFFFFFFFF/CSNLOG_XACTS_PER_PAGE, and segment numbering at
 * 0xFFFFFFFF/CSNLOG_XACTS_PER_PAGE/SLRU_PAGES_PER_SEGMENT.  We need take no
 * explicit notice of that fact in this module, except when comparing segment
 * and page numbers in TruncateCSNLOG (see CSNLogPagePrecedes) and zeroing
 * them in StartupCSNLOG.
 */

/* We need eight bytes per xact */
#define CSNLOG_XACTS_PER_PAGE (BLCKSZ / sizeof(CommitSeqNo))

static inline int64
TransactionIdToPage(TransactionId xid)
{
	return xid / (int64) CSNLOG_XACTS_PER_PAGE;
}

#define TransactionIdToEntry(xid) ((xid) % (TransactionId) CSNLOG_XACTS_PER_PAGE)


static void CSNLOGShmemRequest(void *arg);
static void CSNLOGShmemInit(void *arg);
static bool CSNLogPagePrecedes(int64 page1, int64 page2);
static int	csnlog_errdetail_for_io_error(const void *opaque_data);
static void CSNLogSetPageEntries(int64 pageno, TransactionId xid,
								 int nsubxids, const TransactionId *subxids,
								 CommitSeqNo csn);

const ShmemCallbacks CSNLOGShmemCallbacks = {
	.request_fn = CSNLOGShmemRequest,
	.init_fn = CSNLOGShmemInit,
};

/*
 * Link to shared-memory data structures for CSNLOG control
 */
static SlruDesc CSNLogSlruDesc;

#define CSNLogCtl  (&CSNLogSlruDesc)


/*
 * Check that a proposed entry transition is sane.  Entries can legally be
 * rewritten during recovery (e.g. a FROZEN entry seeded from pg_xact can
 * later be overwritten with the real CSN when the commit record is
 * replayed after a restartpoint), but a committed entry must never turn
 * into an aborted one or vice versa.
 */
static inline void
CSNLogAssertTransition(CommitSeqNo oldcsn, CommitSeqNo newcsn)
{
#ifdef USE_ASSERT_CHECKING
	bool		oldcommitted = COMMITSEQNO_IS_COMMITTED(oldcsn);
	bool		newcommitted = COMMITSEQNO_IS_COMMITTED(newcsn);

	if (oldcsn == InvalidCommitSeqNo || oldcsn == CSN_COMMITTING)
		return;					/* anything goes */
	Assert(!(oldcommitted && newcsn == CSN_ABORTED));
	Assert(!(oldcsn == CSN_ABORTED && newcommitted));
	Assert(newcsn != CSN_COMMITTING || oldcommitted == false);
#endif
}

/*
 * Set entries for the given page.  xid may be InvalidTransactionId if the
 * top-level XID lives on a different page than this batch of subxids.
 */
static void
CSNLogSetPageEntries(int64 pageno, TransactionId xid,
					 int nsubxids, const TransactionId *subxids,
					 CommitSeqNo csn)
{
	int			slotno;
	CommitSeqNo *ptr;
	LWLock	   *lock;
	int			i;

	lock = SimpleLruGetBankLock(CSNLogCtl, pageno);
	LWLockAcquire(lock, LW_EXCLUSIVE);

	slotno = SimpleLruReadPage(CSNLogCtl, pageno, true, &xid);
	ptr = (CommitSeqNo *) CSNLogCtl->shared->page_buffer[slotno];

	if (TransactionIdIsValid(xid))
	{
		Assert(TransactionIdToPage(xid) == pageno);
		CSNLogAssertTransition(ptr[TransactionIdToEntry(xid)], csn);
		ptr[TransactionIdToEntry(xid)] = csn;
	}

	for (i = 0; i < nsubxids; i++)
	{
		Assert(TransactionIdToPage(subxids[i]) == pageno);
		CSNLogAssertTransition(ptr[TransactionIdToEntry(subxids[i])], csn);
		ptr[TransactionIdToEntry(subxids[i])] = csn;
	}

	CSNLogCtl->shared->page_dirty[slotno] = true;

	LWLockRelease(lock);
}

/*
 * Set the same CSN log value for an entire transaction tree.
 *
 * xid is the top-level XID and subxids[] its subtransactions' XIDs, sorted
 * in ascending XID order (which is how the callers naturally have them:
 * both PGPROC caches and commit/abort records store subxids in assignment
 * order).  The entries are updated page by page, so the cost is bounded by
 * the number of touched pages rather than the number of XIDs.
 *
 * Unlike pg_xact updates, this does not need to distinguish a "committed"
 * from a "sub-committed" intermediate state: visibility of the whole tree
 * flips atomically when the tree's CSN is assigned from
 * TransamVariables->lastCommitSeqNo (under ProcArrayLock), not when the
 * entries are stamped.
 */
void
CSNLogSetCommitSeqNo(TransactionId xid, int nsubxids,
					 TransactionId *subxids, CommitSeqNo csn)
{
	int64		toppage;
	int			i;

	Assert(TransactionIdIsValid(xid));

	toppage = TransactionIdToPage(xid);

	/* Leading subxids that share the top-level XID's page */
	i = 0;
	while (i < nsubxids && TransactionIdToPage(subxids[i]) == toppage)
		i++;
	CSNLogSetPageEntries(toppage, xid, i, subxids, csn);

	/* Remaining subxids, one page at a time */
	while (i < nsubxids)
	{
		int64		pageno = TransactionIdToPage(subxids[i]);
		int			j = i;

		while (j < nsubxids && TransactionIdToPage(subxids[j]) == pageno)
			j++;
		CSNLogSetPageEntries(pageno, InvalidTransactionId,
							 j - i, subxids + i, csn);
		i = j;
	}
}

/*
 * Mark a transaction tree as "committing".
 *
 * This must be called (under a critical section) immediately before the
 * tree's CSN is assigned and published, so that a reader whose snapshot
 * could already cover the assigned CSN observes at least the
 * CSN_COMMITTING marker and waits for the final value instead of
 * mistaking the transaction for "still in progress".
 */
void
CSNLogSetCommitting(TransactionId xid, int nsubxids, TransactionId *subxids)
{
	CSNLogSetCommitSeqNo(xid, nsubxids, subxids, CSN_COMMITTING);
}

/*
 * Backend-local staging area for the commit currently being finished.
 *
 * The commit path knows the full transaction tree (including subxids that
 * overflowed the PGPROC cache) in RecordTransactionCommit(), but the CSN
 * is only assigned later, when ProcArrayEndTransaction() removes the
 * transaction from the set of running transactions.  RecordTransactionCommit
 * stages the tree here; ProcArrayEndTransaction() marks it committing,
 * has the CSN assigned under ProcArrayLock, and stamps it afterwards.
 *
 * The staged pointers live in TopTransactionContext and remain valid until
 * end of transaction.  A stale entry (in case a commit fails between
 * staging and publication, which implies a PANIC anyway) is guarded
 * against by checking the staged xid against the PGPROC's xid.
 */
static TransactionId stagedCommitXid = InvalidTransactionId;
static int	stagedCommitNSubxids = 0;
static TransactionId *stagedCommitSubxids = NULL;

/*
 * Remember the transaction tree that is about to be committed.
 */
void
CSNLogStageCommit(TransactionId xid, int nsubxids, TransactionId *subxids)
{
	Assert(TransactionIdIsValid(xid));
	stagedCommitXid = xid;
	stagedCommitNSubxids = nsubxids;
	stagedCommitSubxids = subxids;
}

/*
 * Is there a staged commit for the given xid?
 */
bool
CSNLogHasStagedCommit(TransactionId xid)
{
	return TransactionIdIsValid(xid) &&
		TransactionIdEquals(stagedCommitXid, xid);
}

/*
 * Mark the staged transaction tree as committing.
 */
void
CSNLogSetCommittingStaged(void)
{
	Assert(TransactionIdIsValid(stagedCommitXid));
	CSNLogSetCommitting(stagedCommitXid, stagedCommitNSubxids,
						stagedCommitSubxids);
}

/*
 * Stamp the staged transaction tree with its assigned CSN and forget it.
 */
void
CSNLogStampStaged(CommitSeqNo csn)
{
	Assert(TransactionIdIsValid(stagedCommitXid));
	Assert(csn >= FirstNormalCommitSeqNo);
	CSNLogSetCommitSeqNo(stagedCommitXid, stagedCommitNSubxids,
						 stagedCommitSubxids, csn);
	stagedCommitXid = InvalidTransactionId;
	stagedCommitNSubxids = 0;
	stagedCommitSubxids = NULL;
}

/*
 * Read the CSN log entry for the given XID.
 *
 * May return CSN_COMMITTING; callers on the visibility path should use
 * CSNLogGetCommitSeqNoWait() instead.
 *
 * As with pg_subtrans, we may not ask about XIDs that could have been
 * truncated away already; all callers arrive here only for XIDs within
 * their snapshot's [xmin, xmax) window, which the truncation horizon
 * protects.
 */
CommitSeqNo
CSNLogGetCommitSeqNo(TransactionId xid)
{
	int64		pageno = TransactionIdToPage(xid);
	int			entryno = TransactionIdToEntry(xid);
	int			slotno;
	CommitSeqNo csn;

	/* Bootstrap and frozen XIDs are committed and visible to everyone */
	if (!TransactionIdIsNormal(xid))
		return CSN_FROZEN;

	/* lock is acquired by SimpleLruReadPage_ReadOnly */

	slotno = SimpleLruReadPage_ReadOnly(CSNLogCtl, pageno, &xid);
	csn = ((CommitSeqNo *) CSNLogCtl->shared->page_buffer[slotno])[entryno];

	LWLockRelease(SimpleLruGetBankLock(CSNLogCtl, pageno));

	return csn;
}

/*
 * Like CSNLogGetCommitSeqNo(), but if the transaction tree is in the middle
 * of committing, wait until its CSN is known.  The window between marking a
 * tree CSN_COMMITTING and stamping its CSN spans only the CSN assignment in
 * ProcArrayEndTransaction() (including a possible wait for the group-XID-
 * clearing leader); it contains no I/O waits, so a bounded spin is
 * appropriate here.
 */
CommitSeqNo
CSNLogGetCommitSeqNoWait(TransactionId xid)
{
	CommitSeqNo csn;

	csn = CSNLogGetCommitSeqNo(xid);
	if (unlikely(csn == CSN_COMMITTING))
	{
		SpinDelayStatus delayStatus;

		init_local_spin_delay(&delayStatus);
		while ((csn = CSNLogGetCommitSeqNo(xid)) == CSN_COMMITTING)
			perform_spin_delay(&delayStatus);
		finish_spin_delay(&delayStatus);
	}

	return csn;
}

/*
 * Number of shared CSNLOG buffers.
 *
 * There is deliberately no GUC for this: the CSN log is consulted at most
 * once per unhinted tuple (like pg_xact) rather than per tuple per
 * snapshot, so its working set is small and recent.  Auto-tune on shared
 * buffers the same way pg_subtrans does.
 */
static int
CSNLOGShmemBuffers(void)
{
	return SimpleLruAutotuneBuffers(512, 1024);
}

/*
 * Register shared memory for CSNLOG
 */
static void
CSNLOGShmemRequest(void *arg)
{
	SimpleLruRequest(.desc = &CSNLogSlruDesc,
					 .name = "csnlog",
					 .Dir = "pg_csnlog",
					 .long_segment_names = false,

					 .nslots = CSNLOGShmemBuffers(),

					 .sync_handler = SYNC_HANDLER_NONE,
					 .PagePrecedes = CSNLogPagePrecedes,
					 .errdetail_for_io_error = csnlog_errdetail_for_io_error,

					 .buffer_tranche_id = LWTRANCHE_CSNLOG_BUFFER,
					 .bank_tranche_id = LWTRANCHE_CSNLOG_SLRU,
		);
}

static void
CSNLOGShmemInit(void *arg)
{
	SlruPagePrecedesUnitTests(CSNLogCtl, CSNLOG_XACTS_PER_PAGE);
}

/*
 * This func must be called ONCE on system install.  It creates
 * the initial CSNLOG segment.  (The CSNLOG directory is assumed to
 * have been created by initdb, and CSNLOGShmemInit must have been
 * called already.)
 */
void
BootStrapCSNLOG(void)
{
	/* Zero the initial page and flush it to disk */
	SimpleLruZeroAndWritePage(CSNLogCtl, 0);
}

/*
 * This must be called ONCE during postmaster or standalone-backend startup,
 * after StartupXLOG has initialized TransamVariables->nextXid.
 *
 * oldestActiveXID is the oldest XID of any prepared transaction, or nextXid
 * if there are none.
 *
 * Since we don't expect pg_csnlog to be valid across crashes, we initialize
 * the currently-active page(s) to zeroes during startup, just like
 * pg_subtrans.  Whenever we advance into a new page, ExtendCSNLOG will
 * likewise zero the new page without regard to whatever was previously on
 * disk.
 *
 * If fillFromCLOG is true (hot standby startup), additionally seed the
 * entries in [oldestActiveXID, nextXid) from pg_xact: transactions that
 * completed before the WAL replay window began will not have their commit
 * or abort records replayed, but standby queries may inspect their XIDs.
 * Transactions that committed before this server started recovering
 * necessarily committed before any snapshot this server will ever take, so
 * marking them CSN_FROZEN (visible to everyone) is correct.  XIDs that
 * pg_xact shows as still in progress are left as InvalidCommitSeqNo: they
 * either belong to transactions that are still running on the primary (in
 * which case their commit record will be replayed and stamped normally),
 * or they crashed and will never be visible.
 */
void
StartupCSNLOG(TransactionId oldestActiveXID, bool fillFromCLOG)
{
	FullTransactionId fnextXid;
	TransactionId nextXid;
	int64		startPage;
	int64		endPage;
	LWLock	   *prevlock = NULL;
	LWLock	   *lock;

	startPage = TransactionIdToPage(oldestActiveXID);
	fnextXid = TransamVariables->nextXid;
	nextXid = XidFromFullTransactionId(fnextXid);
	endPage = TransactionIdToPage(nextXid);

	for (;;)
	{
		lock = SimpleLruGetBankLock(CSNLogCtl, startPage);
		if (prevlock != lock)
		{
			if (prevlock)
				LWLockRelease(prevlock);
			LWLockAcquire(lock, LW_EXCLUSIVE);
			prevlock = lock;
		}

		(void) SimpleLruZeroPage(CSNLogCtl, startPage);
		if (startPage == endPage)
			break;

		startPage++;
		/* must account for wraparound */
		if (startPage > TransactionIdToPage(MaxTransactionId))
			startPage = 0;
	}

	LWLockRelease(lock);

	if (fillFromCLOG)
	{
		TransactionId xid = oldestActiveXID;

		while (TransactionIdPrecedes(xid, nextXid))
		{
			if (TransactionIdIsNormal(xid))
			{
				if (TransactionIdDidCommit(xid))
					CSNLogSetCommitSeqNo(xid, 0, NULL, CSN_FROZEN);
				else if (TransactionIdDidAbort(xid))
					CSNLogSetCommitSeqNo(xid, 0, NULL, CSN_ABORTED);
			}
			TransactionIdAdvance(xid);
		}
	}
}

/*
 * Perform a checkpoint --- either during shutdown, or on-the-fly
 */
void
CheckPointCSNLOG(void)
{
	/*
	 * Write dirty CSNLOG pages to disk.
	 *
	 * This is not actually necessary from a correctness point of view (see
	 * the crash-safety discussion in the file header).  We do it merely to
	 * improve the odds that writing of dirty pages is done by the checkpoint
	 * process and not by backends.
	 */
	SimpleLruWriteAll(CSNLogCtl, true);
}

/*
 * Make sure that CSNLOG has room for a newly-allocated XID.
 *
 * NB: this is called while holding XidGenLock.  We want it to be very fast
 * most of the time; even when it's not so fast, no actual I/O need happen
 * unless we're forced to write out a dirty csnlog page to make room in
 * shared memory.
 */
void
ExtendCSNLOG(TransactionId newestXact)
{
	int64		pageno;
	LWLock	   *lock;

	/*
	 * No work except at first XID of a page.  But beware: just after
	 * wraparound, the first XID of page zero is FirstNormalTransactionId.
	 */
	if (TransactionIdToEntry(newestXact) != 0 &&
		!TransactionIdEquals(newestXact, FirstNormalTransactionId))
		return;

	pageno = TransactionIdToPage(newestXact);

	lock = SimpleLruGetBankLock(CSNLogCtl, pageno);
	LWLockAcquire(lock, LW_EXCLUSIVE);

	/* Zero the page */
	SimpleLruZeroPage(CSNLogCtl, pageno);

	LWLockRelease(lock);
}

/*
 * Remove all CSNLOG segments before the one holding the passed
 * transaction ID.
 *
 * oldestXact is the oldest TransactionXmin of any running transaction.
 * This is called only during checkpoint.  The horizon is the same one that
 * protects pg_subtrans: no snapshot can ask about an XID older than its
 * xmin, and every snapshot's xmin is >= the computed oldest xmin.
 */
void
TruncateCSNLOG(TransactionId oldestXact)
{
	int64		cutoffPage;

	/*
	 * The cutoff point is the start of the segment containing oldestXact. We
	 * pass the *page* containing oldestXact to SimpleLruTruncate.  We step
	 * back one transaction to avoid passing a cutoff page that hasn't been
	 * created yet in the rare case that oldestXact would be the first item on
	 * a page and oldestXact == next XID.  In that case, if we didn't subtract
	 * one, we'd trigger SimpleLruTruncate's wraparound detection.
	 */
	TransactionIdRetreat(oldestXact);
	cutoffPage = TransactionIdToPage(oldestXact);

	SimpleLruTruncate(CSNLogCtl, cutoffPage);
}

/*
 * Decide whether a CSNLOG page number is "older" for truncation purposes.
 * Analogous to CLOGPagePrecedes().
 */
static bool
CSNLogPagePrecedes(int64 page1, int64 page2)
{
	TransactionId xid1;
	TransactionId xid2;

	xid1 = ((TransactionId) page1) * CSNLOG_XACTS_PER_PAGE;
	xid1 += FirstNormalTransactionId + 1;
	xid2 = ((TransactionId) page2) * CSNLOG_XACTS_PER_PAGE;
	xid2 += FirstNormalTransactionId + 1;

	return (TransactionIdPrecedes(xid1, xid2) &&
			TransactionIdPrecedes(xid1, xid2 + CSNLOG_XACTS_PER_PAGE - 1));
}

static int
csnlog_errdetail_for_io_error(const void *opaque_data)
{
	TransactionId xid = *(const TransactionId *) opaque_data;

	return errdetail("Could not access commit sequence number of transaction %u.", xid);
}
