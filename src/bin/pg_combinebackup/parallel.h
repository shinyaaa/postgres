/*-------------------------------------------------------------------------
 *
 * parallel.h
 *		Worker processes for pg_combinebackup.
 *
 * Copyright (c) 2017-2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  src/bin/pg_combinebackup/parallel.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef PARALLEL_H
#define PARALLEL_H

#include "lib/stringinfo.h"

struct cb_worker_pool;
typedef struct cb_worker_pool cb_worker_pool;

/*
 * Called once in each worker process, before it starts accepting jobs.
 */
typedef void (*cb_worker_init_callback) (void *arg);

/*
 * Called in a worker process to perform one job. The job is an opaque byte
 * string provided by the leader. Whatever the callback appends to result is
 * sent back to the leader.
 */
typedef void (*cb_job_callback) (char *job, size_t joblen,
								 StringInfo result, void *arg);

/*
 * Called in the leader when a worker has completed a job. tag is whatever
 * was passed to cb_worker_pool_dispatch() for that job.
 */
typedef void (*cb_result_callback) (void *tag, char *result,
									size_t resultlen, void *arg);

extern cb_worker_pool *cb_worker_pool_start(int nworkers,
											cb_worker_init_callback init_cb,
											cb_job_callback job_cb,
											cb_result_callback result_cb,
											void *arg);
extern void cb_worker_pool_dispatch(cb_worker_pool *pool,
									const char *job, size_t joblen,
									void *tag);
extern void cb_worker_pool_finish(cb_worker_pool *pool);

#endif							/* PARALLEL_H */
