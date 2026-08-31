/*-------------------------------------------------------------------------
 *
 * parallel.c
 *		Worker processes for pg_combinebackup.
 *
 * The leader forks a fixed number of worker processes up front and hands
 * each of them one job at a time. Jobs and results are opaque byte strings
 * that travel over a pair of pipes per worker, each prefixed with its
 * length. A worker runs the job callback for every job it receives and
 * sends back whatever that callback produces. The leader hands out a new
 * job as soon as a worker becomes idle and delivers each result to the
 * result callback.
 *
 * A worker reports errors the same way the leader does, by calling
 * pg_fatal(). The leader notices that the worker's result pipe has been
 * closed and exits as well. Conversely, if the leader exits while workers
 * are still running, it terminates them first, so that they do not keep
 * writing into an output directory that is about to be removed.
 *
 * Copyright (c) 2017-2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *	  src/bin/pg_combinebackup/parallel.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres_fe.h"

#ifndef WIN32
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef HAVE_SYS_SELECT_H
#include <sys/select.h>
#endif
#endif

#include "common/logging.h"
#include "parallel.h"

#ifndef WIN32

typedef struct cb_worker
{
	pid_t		pid;
	int			job_fd;			/* leader's write end of the job pipe */
	int			result_fd;		/* leader's read end of the result pipe */
	bool		busy;			/* has a job it has not reported on yet */
	void	   *tag;			/* caller's tag for that job */
} cb_worker;

struct cb_worker_pool
{
	pid_t		leader_pid;
	int			nworkers;
	cb_worker  *workers;
	cb_result_callback result_cb;
	void	   *arg;
};

/* The pool whose workers are to be terminated if the leader exits early. */
static cb_worker_pool *active_pool = NULL;

static void collect_results(cb_worker_pool *pool, bool wait);
static void terminate_workers_atexit(void);
pg_noreturn static void run_worker(int job_fd, int result_fd,
								   cb_worker_init_callback init_cb,
								   cb_job_callback job_cb, void *arg);
static void send_message(int fd, const char *data, size_t len);
static bool receive_message(int fd, StringInfo buf);
static bool write_fully(int fd, const void *data, size_t len);
static int	read_fully(int fd, void *data, size_t len);

/*
 * Fork the requested number of worker processes.
 *
 * Every worker starts by calling init_cb, and then runs job_cb once per job
 * until the leader calls cb_worker_pool_finish(). arg is passed through to
 * all three callbacks. The state that the workers need must therefore be
 * set up before this function is called, since they inherit it by fork().
 */
cb_worker_pool *
cb_worker_pool_start(int nworkers, cb_worker_init_callback init_cb,
					 cb_job_callback job_cb, cb_result_callback result_cb,
					 void *arg)
{
	cb_worker_pool *pool;

	Assert(nworkers > 1);

	pool = pg_malloc0_object(cb_worker_pool);
	pool->leader_pid = getpid();
	pool->nworkers = nworkers;
	pool->workers = pg_malloc0_array(cb_worker, nworkers);
	pool->result_cb = result_cb;
	pool->arg = arg;

	/*
	 * A worker that dies takes its pipes with it. We want to find out about
	 * that by getting EPIPE from the next write, not by being killed.
	 */
	pqsignal(SIGPIPE, PG_SIG_IGN);

	/*
	 * Arrange to terminate the workers if we exit early. This must be
	 * registered after the handler that removes the output directories, so
	 * that it runs before it.
	 */
	active_pool = pool;
	atexit(terminate_workers_atexit);

	for (int i = 0; i < nworkers; ++i)
	{
		cb_worker  *w = &pool->workers[i];
		int			job_pipe[2];
		int			result_pipe[2];
		pid_t		pid;

		if (pipe(job_pipe) < 0 || pipe(result_pipe) < 0)
			pg_fatal("could not create pipe: %m");

		/*
		 * The result pipes are the ones we select() on, so their descriptors
		 * must fit in an fd_set.
		 */
		if (result_pipe[0] >= FD_SETSIZE)
			pg_fatal("too many parallel jobs requested (maximum is %d)",
					 i);

		/* Ensure stdio state is quiesced before forking */
		fflush(NULL);

		pid = fork();
		if (pid < 0)
			pg_fatal("could not create worker process: %m");

		if (pid == 0)
		{
			/*
			 * Child. Close the leader's ends of our own pipes and every
			 * descriptor belonging to a previously started worker, so that
			 * each worker sees end-of-file on its job pipe as soon as the
			 * leader closes its end.
			 */
			close(job_pipe[1]);
			close(result_pipe[0]);
			for (int j = 0; j < i; ++j)
			{
				close(pool->workers[j].job_fd);
				close(pool->workers[j].result_fd);
			}

			pqsignal(SIGPIPE, PG_SIG_DFL);

			run_worker(job_pipe[0], result_pipe[1], init_cb, job_cb, arg);
		}

		/* Parent. */
		close(job_pipe[0]);
		close(result_pipe[1]);
		w->pid = pid;
		w->job_fd = job_pipe[1];
		w->result_fd = result_pipe[0];
		w->busy = false;
		w->tag = NULL;
	}

	return pool;
}

/*
 * Hand a job to an idle worker, waiting for one to become idle if necessary.
 *
 * Any results that have arrived in the meantime are delivered to the result
 * callback before this function returns.
 */
void
cb_worker_pool_dispatch(cb_worker_pool *pool, const char *job, size_t joblen,
						void *tag)
{
	cb_worker  *w = NULL;

	/* Deliver whatever results are already waiting for us. */
	collect_results(pool, false);

	/* Wait until some worker is idle. */
	for (;;)
	{
		for (int i = 0; i < pool->nworkers; ++i)
		{
			if (!pool->workers[i].busy)
			{
				w = &pool->workers[i];
				break;
			}
		}
		if (w != NULL)
			break;
		collect_results(pool, true);
	}

	w->busy = true;
	w->tag = tag;
	send_message(w->job_fd, job, joblen);
}

/*
 * Wait for all outstanding jobs to complete, deliver their results, and
 * reap the worker processes.
 */
void
cb_worker_pool_finish(cb_worker_pool *pool)
{
	/* Closing the job pipe tells the worker that there is no more work. */
	for (int i = 0; i < pool->nworkers; ++i)
	{
		close(pool->workers[i].job_fd);
		pool->workers[i].job_fd = -1;
	}

	for (;;)
	{
		bool		busy = false;

		for (int i = 0; i < pool->nworkers; ++i)
		{
			if (pool->workers[i].busy)
			{
				busy = true;
				break;
			}
		}
		if (!busy)
			break;
		collect_results(pool, true);
	}

	for (int i = 0; i < pool->nworkers; ++i)
	{
		cb_worker  *w = &pool->workers[i];
		int			status;

		close(w->result_fd);
		w->result_fd = -1;

		if (waitpid(w->pid, &status, 0) != w->pid)
			pg_fatal("%s() failed: %m", "waitpid");
		w->pid = 0;
		if (status != 0)
			pg_fatal("%s", wait_result_to_str(status));
	}

	active_pool = NULL;
}

/*
 * Read results from workers that have some to report, and deliver them to
 * the result callback. If wait is true, block until at least one result
 * has been delivered; otherwise, return at once if none is available.
 */
static void
collect_results(cb_worker_pool *pool, bool wait)
{
	StringInfoData buf;

	initStringInfo(&buf);

	for (;;)
	{
		fd_set		readfds;
		int			maxfd = -1;
		struct timeval nowait = {0, 0};
		int			rc;
		bool		delivered = false;

		FD_ZERO(&readfds);
		for (int i = 0; i < pool->nworkers; ++i)
		{
			cb_worker  *w = &pool->workers[i];

			if (!w->busy)
				continue;
			FD_SET(w->result_fd, &readfds);
			maxfd = Max(maxfd, w->result_fd);
		}

		/* Nothing outstanding, so nothing to wait for. */
		if (maxfd < 0)
			break;

		rc = select(maxfd + 1, &readfds, NULL, NULL, wait ? NULL : &nowait);
		if (rc < 0)
		{
			if (errno == EINTR)
				continue;
			pg_fatal("%s() failed: %m", "select");
		}
		if (rc == 0)
			break;

		for (int i = 0; i < pool->nworkers; ++i)
		{
			cb_worker  *w = &pool->workers[i];

			if (!w->busy || !FD_ISSET(w->result_fd, &readfds))
				continue;

			if (!receive_message(w->result_fd, &buf))
				pg_fatal("worker process exited unexpectedly");

			w->busy = false;
			pool->result_cb(w->tag, buf.data, buf.len, pool->arg);
			w->tag = NULL;
			delivered = true;
		}

		if (delivered || !wait)
			break;
	}

	pfree(buf.data);
}

/*
 * Terminate any workers that are still running. This is an atexit handler,
 * so it runs when the leader exits early because of an error; a normal exit
 * reaps all the workers in cb_worker_pool_finish() first.
 */
static void
terminate_workers_atexit(void)
{
	cb_worker_pool *pool = active_pool;

	/* The workers inherit this handler, but it is not for them. */
	if (pool == NULL || getpid() != pool->leader_pid)
		return;

	for (int i = 0; i < pool->nworkers; ++i)
	{
		if (pool->workers[i].pid > 0)
			kill(pool->workers[i].pid, SIGTERM);
	}
	for (int i = 0; i < pool->nworkers; ++i)
	{
		if (pool->workers[i].pid > 0)
			waitpid(pool->workers[i].pid, NULL, 0);
	}
}

/*
 * Main loop of a worker process. Never returns.
 */
static void
run_worker(int job_fd, int result_fd, cb_worker_init_callback init_cb,
		   cb_job_callback job_cb, void *arg)
{
	StringInfoData job;
	StringInfoData result;

	init_cb(arg);

	initStringInfo(&job);
	initStringInfo(&result);

	/* End-of-file on the job pipe means that the leader has no more work. */
	while (receive_message(job_fd, &job))
	{
		resetStringInfo(&result);
		job_cb(job.data, job.len, &result, arg);
		send_message(result_fd, result.data, result.len);
	}

	exit(0);
}

/*
 * Write a length-prefixed message to a pipe.
 */
static void
send_message(int fd, const char *data, size_t len)
{
	uint32		hdr = len;

	Assert(len <= PG_UINT32_MAX);

	if (!write_fully(fd, &hdr, sizeof(hdr)) ||
		!write_fully(fd, data, len))
	{
		if (errno == EPIPE)
			pg_fatal("worker process exited unexpectedly");
		pg_fatal("could not write to pipe: %m");
	}
}

/*
 * Read a length-prefixed message from a pipe into buf, replacing whatever
 * buf contained before. Returns false if the other end has been closed.
 */
static bool
receive_message(int fd, StringInfo buf)
{
	uint32		hdr;
	int			rc;

	rc = read_fully(fd, &hdr, sizeof(hdr));
	if (rc == 0)
		return false;
	if (rc < 0)
		pg_fatal("could not read from pipe: %m");

	resetStringInfo(buf);
	enlargeStringInfo(buf, hdr);
	rc = read_fully(fd, buf->data, hdr);
	if (rc <= 0)
	{
		if (rc == 0)
			pg_fatal("unexpected end of message from pipe");
		pg_fatal("could not read from pipe: %m");
	}
	buf->len = hdr;
	buf->data[hdr] = '\0';

	return true;
}

/*
 * Write exactly len bytes, retrying on short writes. Returns false on error,
 * with errno set.
 */
static bool
write_fully(int fd, const void *data, size_t len)
{
	const char *p = data;

	while (len > 0)
	{
		ssize_t		wb = write(fd, p, len);

		if (wb < 0)
		{
			if (errno == EINTR)
				continue;
			return false;
		}
		p += wb;
		len -= wb;
	}

	return true;
}

/*
 * Read exactly len bytes, retrying on short reads. Returns 1 on success, 0
 * if the other end was closed before any byte arrived, and -1 on error,
 * with errno set. Getting only part of the requested data before
 * end-of-file is also reported as an error.
 */
static int
read_fully(int fd, void *data, size_t len)
{
	char	   *p = data;
	size_t		got = 0;

	while (got < len)
	{
		ssize_t		rb = read(fd, p + got, len - got);

		if (rb < 0)
		{
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (rb == 0)
		{
			if (got == 0)
				return 0;
			errno = EIO;
			return -1;
		}
		got += rb;
	}

	return 1;
}

#else							/* WIN32 */

/*
 * Parallel operation is not implemented on Windows yet. The option is
 * rejected before we get here, so these exist only to satisfy the linker.
 */
cb_worker_pool *
cb_worker_pool_start(int nworkers, cb_worker_init_callback init_cb,
					 cb_job_callback job_cb, cb_result_callback result_cb,
					 void *arg)
{
	pg_fatal("parallel jobs are not supported on this platform");
}

void
cb_worker_pool_dispatch(cb_worker_pool *pool, const char *job, size_t joblen,
						void *tag)
{
	pg_fatal("parallel jobs are not supported on this platform");
}

void
cb_worker_pool_finish(cb_worker_pool *pool)
{
	pg_fatal("parallel jobs are not supported on this platform");
}

#endif							/* WIN32 */
