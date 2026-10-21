///|
struct Sqlite3CleanupJob(Sqlite3Job)

///|
#borrow(rescode)
extern "c" fn cleanup_job_create(
  executor : Sqlite3ExecutorHandle,
  database : Sqlite3Handle,
  statement : Sqlite3StmtHandle,
  notification : @pipe.Fd,
  rescode : Ref[Int32],
) -> Sqlite3JobHandle = "moonrun_sqlite3_cleanup_job_create"

///|
extern "c" fn cleanup_job_release(job : Sqlite3JobHandle) -> Unit = "moonrun_sqlite3_cleanup_job_release"

///|
extern "c" fn null_statement() -> Sqlite3StmtHandle = "moonrun_sqlite3_null_statement"

///|
/// Submit cleanup. A statement is consumed only when rescode is SQLITE_OK.
/// Keep the database and executor alive until wait and release complete.
pub fn sqlite3_finalize_job(
  executor : Sqlite3Executor,
  database : Sqlite3,
  statement : Sqlite3Stmt,
  rescode : Ref[Int32],
) -> Sqlite3CleanupJob raise {
  new_cleanup_job(executor, database, statement.0, rescode)
}

///|
/// Submit connection close. The caller retains the database on failure and
/// releases the idle executor after waiting and releasing this job.
pub fn sqlite3_close_job(
  executor : Sqlite3Executor,
  database : Sqlite3,
  rescode : Ref[Int32],
) -> Sqlite3CleanupJob raise {
  new_cleanup_job(executor, database, null_statement(), rescode)
}

///|
fn new_cleanup_job(
  executor : Sqlite3Executor,
  database : Sqlite3,
  statement : Sqlite3StmtHandle,
  rescode : Ref[Int32],
) -> Sqlite3CleanupJob raise {
  let (reader, writer) = @pipe.pipe()
  defer writer.close()
  Sqlite3CleanupJob({
    handle: cleanup_job_create(
      executor.0,
      database.0,
      statement,
      writer.fd(),
      rescode,
    ),
    notification: Some(reader),
  })
}

///|
/// Await completion under cancellation protection; cleanup itself is not cancelled.
pub fn Sqlite3CleanupJob::wait(self : Sqlite3CleanupJob) -> Unit {
  self.0.wait()
}

///|
pub fn Sqlite3CleanupJob::result(
  self : Sqlite3CleanupJob,
) -> (Int32, Int32, String) {
  (self.0.rescode(), self.0.extended_rescode(), self.0.message())
}

///|
pub fn Sqlite3CleanupJob::release(self : Sqlite3CleanupJob) -> Unit {
  self.0.close_notification()
  cleanup_job_release(self.0.handle)
}

///|
pub fn Sqlite3CleanupJob::notification_fd(self : Sqlite3CleanupJob) -> @pipe.Fd {
  self.0.notification.unwrap().fd()
}
