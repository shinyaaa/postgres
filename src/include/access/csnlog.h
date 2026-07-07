/*
 * csnlog.h
 *
 * PostgreSQL commit-sequence-number log manager
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/include/access/csnlog.h
 */
#ifndef CSNLOG_H
#define CSNLOG_H

#include "access/transam.h"
#include "access/xlogdefs.h"

extern void CSNLogSetCommitting(TransactionId xid, int nsubxids,
								TransactionId *subxids);
extern void CSNLogStageCommit(TransactionId xid, int nsubxids,
							  TransactionId *subxids);
extern bool CSNLogHasStagedCommit(TransactionId xid);
extern void CSNLogSetCommittingStaged(void);
extern void CSNLogStampStaged(CommitSeqNo csn);
extern void CSNLogSetCommitSeqNo(TransactionId xid, int nsubxids,
								 TransactionId *subxids, CommitSeqNo csn);
extern CommitSeqNo CSNLogGetCommitSeqNo(TransactionId xid);
extern CommitSeqNo CSNLogGetCommitSeqNoWait(TransactionId xid);

extern void BootStrapCSNLOG(void);
extern void StartupCSNLOG(TransactionId oldestActiveXID, bool fillFromCLOG);
extern void CheckPointCSNLOG(void);
extern void ExtendCSNLOG(TransactionId newestXact);
extern void TruncateCSNLOG(TransactionId oldestXact);

#endif							/* CSNLOG_H */
