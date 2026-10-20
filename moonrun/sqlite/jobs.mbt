///|
priv enum Input {
  Open(@filesystem.HostFs, Bytes, Int32)
  Prepare(Database, String)
  Step(Statement)
  Finalize(Statement)
  Close(Database)
}

///|
priv enum Output {
  Opened(Database)
  Prepared(Statement)
}

///|
pub struct Outcome {
  code : Int32
  extended : Int32
  message : String
  tail : Int32
  changes : Int64?
  priv mut output : Output?
}

///|
pub struct Job {
  priv mut input : Input?
  priv database : Database?
  priv statement : Statement?
  priv mut closed : Bool
  priv mut result : Outcome?
}

///|
fn outcome(
  code : Int32,
  extended? : Int32,
  message~ : String = "",
  tail~ : Int32 = -1,
  changes? : Int64,
  output? : Output,
) -> Outcome {
  { code, extended: extended.unwrap_or(code), message, tail, changes, output, }
}

///|
fn new_job(input : Input, database? : Database, statement? : Statement) -> Job {
  if database is Some(database) {
    database.leases += 1
  }
  if statement is Some(statement) {
    statement.leased = true
  }
  { input: Some(input), database, statement, closed: false, result: None, }
}

///|
fn HostSqlite::database_for_job(
  self : HostSqlite,
  handle : Int64,
) -> Database raise SqliteError {
  let database = self.database(handle)
  guard database.ready && database.depth == 0 else { raise Fault }
  database
}

///|
pub fn HostSqlite::make_open_job(
  self : HostSqlite,
  filename : Bytes,
  flags : Int32,
) -> Job {
  new_job(Open(self.filesystem, filename, normalize_open_flags(flags)))
}

///|
pub fn HostSqlite::make_prepare_job(
  self : HostSqlite,
  handle : Int64,
  sql : String,
) -> Job raise SqliteError {
  let database = self.database_for_job(handle)
  new_job(Prepare(database, sql), database~)
}

///|
pub fn HostSqlite::make_step_job(
  self : HostSqlite,
  handle : Int64,
  statement : Int64,
) -> Job raise SqliteError {
  let database = self.database_for_job(handle)
  let statement = self.statement(statement)
  guard physical_equal(statement.database, database) else { raise Fault }
  new_job(Step(statement), database~, statement~)
}

///|
pub fn HostSqlite::make_finalize_job(
  self : HostSqlite,
  handle : Int64,
  statement_handle : Int64,
) -> Job raise SqliteError {
  let database = self.database_for_job(handle)
  let statement = self.statement(statement_handle)
  guard physical_equal(statement.database, database) else { raise Fault }
  self.statements.remove(statement_handle)
  new_job(Finalize(statement), database~)
}

///|
pub fn Job::outcome(self : Job) -> Outcome raise SqliteError {
  guard !self.closed && self.result is Some(result) else { raise Fault }
  result
}

///|
pub fn HostSqlite::take_job_handle(
  self : HostSqlite,
  job : Job,
) -> Int64 raise SqliteError {
  let result = job.outcome()
  guard result.code == 0 && result.output is Some(output) else { raise Fault }
  result.output = None
  match output {
    Opened(database) => self.publish_database(database)
    Prepared(statement) => self.publish_statement(statement)
  }
}

///|
pub fn Job::discard(self : Job) -> Job? raise SqliteError {
  let result = self.outcome()
  guard result.output is Some(output) else { return None }
  result.output = None
  Some(
    match output {
      Opened(database) => new_job(Close(database))
      Prepared(statement) =>
        new_job(Finalize(statement), database=statement.database)
    },
  )
}

///|
fn close_owned(database : Database) -> Unit {
  @ffi.sqlite3_executor_release(database.executor)
  ignore(@ffi.sqlite3_close(database.pointer))
}

///|
pub fn Job::close(self : Job) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  if self.input is Some(Finalize(statement)) {
    ignore(@ffi.sqlite3_finalize(statement.pointer))
  }
  if self.input is Some(Close(database)) {
    close_owned(database)
  }
  self.input = None
  if self.result is Some(result) && result.output is Some(output) {
    result.output = None
    match output {
      Opened(database) => close_owned(database)
      Prepared(statement) => ignore(@ffi.sqlite3_finalize(statement.pointer))
    }
  }
  if self.statement is Some(statement) {
    statement.leased = false
  }
  if self.database is Some(database) {
    database.leases -= 1
  }
}

///|
pub async fn Job::run(self : Job) -> @resource.JobResult {
  guard !self.closed && self.input is Some(input) else { raise Fault }
  // A native operation and its owned result must survive cancellation together.
  @async.protect_from_cancel(() => {
    self.input = None
    self.result = Some(
      match input {
        Open(filesystem, filename, flags) =>
          open_job(filesystem, filename, flags)
        Prepare(database, sql) => prepare_job(database, sql)
        Step(statement) => step_job(statement)
        Finalize(statement) => cleanup_job(statement.database, Some(statement))
        Close(database) => cleanup_job(database, None)
      },
    )
  })
  let result = self.outcome()
  { ret: result.code, errno: 0, data: b"", opened: None, }
}
