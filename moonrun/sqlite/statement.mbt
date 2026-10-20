///|
fn HostSqlite::publish_statement(
  self : HostSqlite,
  statement : Statement,
) -> Int64 {
  let handle = self.handles.allocate()
  self.statements[handle] = statement
  handle
}

///|
pub fn HostSqlite::prepare(
  self : HostSqlite,
  handle : Int64,
  sql : String,
) -> (Int32, Int64, Int32) raise SqliteError {
  let database = self.database(handle)
  if !database.ready {
    return (21, self.handles.null_handle, 0)
  }
  let code = Ref(0)
  let tail = Ref(0)
  let pointer = @ffi.sqlite3_prepare16_v2_raw(database.pointer, sql, tail, code)
  let statement = if @ffi.sqlite3_stmt_is_null(pointer) {
    self.handles.null_handle
  } else {
    self.publish_statement({ pointer, database, leased: false, row: false, })
  }
  (code.val, statement, tail.val)
}

///|
pub fn HostSqlite::step(
  self : HostSqlite,
  handle : Int64,
) -> Int32 raise SqliteError {
  let statement = self.statement(handle)
  let code = @ffi.sqlite3_step(statement.pointer)
  statement.row = code == 100
  code
}

///|
pub fn HostSqlite::reset(
  self : HostSqlite,
  handle : Int64,
) -> Int32 raise SqliteError {
  let statement = self.statement(handle)
  statement.row = false
  @ffi.sqlite3_reset(statement.pointer)
}

///|
pub fn HostSqlite::finalize(
  self : HostSqlite,
  handle : Int64,
) -> Int32 raise SqliteError {
  if handle == self.handles.null_handle {
    return 0
  }
  let statement = self.statement(handle)
  self.statements.remove(handle)
  @ffi.sqlite3_finalize(statement.pointer)
}
