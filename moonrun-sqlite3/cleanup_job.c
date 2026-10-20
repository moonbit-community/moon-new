/* moonrun-owned background statement/database cleanup. */
#include "job.h"
#include <moonbit.h>
#include <stdlib.h>

typedef struct {
  moonbit_sqlite3_job_t job;
  sqlite3 *database;
  sqlite3_stmt *statement;
} moonrun_sqlite3_cleanup_job;

static void run_cleanup(moonbit_sqlite3_executor_job_t *base) {
  moonrun_sqlite3_cleanup_job *cleanup = (moonrun_sqlite3_cleanup_job *)base;
  moonbit_sqlite3_job_t *job = &cleanup->job;
  if (cleanup->statement) {
    sqlite3_mutex *mutex = sqlite3_db_mutex(cleanup->database);
    sqlite3_mutex_enter(mutex);
    job->rescode = sqlite3_finalize(cleanup->statement);
    if (job->rescode == SQLITE_OK) job->extended_rescode = SQLITE_OK;
    else moonbit_sqlite3_job_capture_error(job, cleanup->database);
    sqlite3_mutex_leave(mutex);
  } else {
    job->rescode = sqlite3_close(cleanup->database);
    job->extended_rescode = job->rescode;
  }
  moonbit_sqlite3_job_publish_result(job);
}

MOONBIT_FFI_EXPORT moonbit_sqlite3_job_t *moonrun_sqlite3_cleanup_job_create(
  moonbit_sqlite3_executor_t *executor, sqlite3 *database,
  sqlite3_stmt *statement, moonbit_sqlite3_notification_t notification,
  int32_t *rescode
) {
  if (!database || (statement && sqlite3_db_handle(statement) != database)) {
    *rescode = SQLITE_MISUSE;
    return NULL;
  }
  moonrun_sqlite3_cleanup_job *cleanup = calloc(1, sizeof(*cleanup));
  if (!cleanup) { *rescode = SQLITE_NOMEM; return NULL; }
  cleanup->database = database;
  cleanup->statement = statement;
  if (!moonbit_sqlite3_job_submit(&cleanup->job, executor, notification,
                                 run_cleanup, rescode)) {
    free(cleanup);
    return NULL;
  }
  return &cleanup->job;
}

MOONBIT_FFI_EXPORT void moonrun_sqlite3_cleanup_job_release(
  moonbit_sqlite3_job_t *job
) {
  if (!job) return;
  if (!moonbit_sqlite3_job_result_is_published(job)) abort();
  moonbit_sqlite3_job_dispose(job);
  free(job);
}

MOONBIT_FFI_EXPORT sqlite3_stmt *moonrun_sqlite3_null_statement(void) {
  return NULL;
}
