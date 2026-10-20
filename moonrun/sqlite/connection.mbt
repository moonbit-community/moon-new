///|
fn HostSqlite::publish_database(
  self : HostSqlite,
  database : Database,
) -> Int64 {
  let handle = self.handles.allocate()
  self.databases[handle] = database
  handle
}

///|
fn new_database(
  pointer : @ffi.Sqlite3,
  ready : Bool,
  executor? : @ffi.Sqlite3Executor,
) -> Database raise {
  if executor is Some(executor) {
    return { pointer, executor, ready, mutex: None, depth: 0, leases: 0, }
  }
  let code = Ref(0)
  let executor = @ffi.sqlite3_executor_create(code)
  guard code.val == 0 else {
    ignore(@ffi.sqlite3_close(pointer))
    raise @sys.Operation("failed to create SQLite executor: \{code.val}")
  }
  { pointer, executor, ready, mutex: None, depth: 0, leases: 0, }
}

///|
pub async fn HostSqlite::open_v2(
  self : HostSqlite,
  filename : Bytes,
  flags : Int32,
  vfs : Int64,
) -> (Int32, Int64) {
  if vfs != self.handles.null_handle {
    return (14, self.handles.null_handle)
  }
  guard database_filename(self.filesystem, filename, flags) is Some(filename) else {
    return (14, self.handles.null_handle)
  }
  let code = Ref(0)
  let pointer = @ffi.sqlite3_open_v2(
    filename,
    normalize_open_flags(flags),
    code,
  )
  if @ffi.sqlite3_is_null(pointer) {
    return (code.val, self.handles.null_handle)
  }
  if code.val == 0 {
    code.val = install_authorizer(pointer)
  }
  let database = new_database(pointer, code.val == 0)
  (code.val, self.publish_database(database))
}

///|
pub fn HostSqlite::close_database(
  self : HostSqlite,
  handle : Int64,
) -> Int32 raise SqliteError {
  if handle == self.handles.null_handle {
    return 0
  }
  let database = self.database(handle)
  guard database.depth == 0 && database.leases == 0 else { raise Fault }
  let code = @ffi.sqlite3_close(database.pointer)
  if code == 0 {
    @ffi.sqlite3_executor_release(database.executor)
    if database.mutex is Some(mutex) {
      self.mutexes.remove(mutex)
    }
    self.databases.remove(handle)
  }
  code
}

///|
pub fn HostSqlite::errmsg(
  self : HostSqlite,
  handle : Int64,
) -> String raise SqliteError {
  let database = self.database(handle)
  @ffi.sqlite3_db_mutex_enter(database.pointer)
  defer @ffi.sqlite3_db_mutex_leave(database.pointer)
  @ffi.sqlite3_errmsg(database.pointer)
}

///|
pub fn HostSqlite::errcode(
  self : HostSqlite,
  handle : Int64,
  extended : Bool,
) -> Int32 raise SqliteError {
  let database = self.database(handle)
  @ffi.sqlite3_db_mutex_enter(database.pointer)
  defer @ffi.sqlite3_db_mutex_leave(database.pointer)
  if extended {
    @ffi.sqlite3_extended_errcode(database.pointer)
  } else {
    @ffi.sqlite3_errcode(database.pointer)
  }
}

///|
pub fn HostSqlite::changes64(
  self : HostSqlite,
  handle : Int64,
) -> Int64 raise SqliteError {
  let database = self.database(handle)
  @ffi.sqlite3_db_mutex_enter(database.pointer)
  defer @ffi.sqlite3_db_mutex_leave(database.pointer)
  @ffi.sqlite3_changes64(database.pointer)
}
