///|
pub fn HostSqlite::db_mutex(
  self : HostSqlite,
  handle : Int64,
) -> Int64 raise SqliteError {
  let database = self.database(handle)
  guard database.ready else { raise Fault }
  if database.mutex is Some(mutex) {
    return mutex
  }
  let mutex = self.handles.allocate()
  self.mutexes[mutex] = database
  database.mutex = Some(mutex)
  mutex
}

///|
pub fn HostSqlite::mutex_enter(
  self : HostSqlite,
  mutex : Int64,
) -> Unit raise SqliteError {
  if mutex == self.handles.null_handle {
    return
  }
  guard self.mutexes.get(mutex) is Some(database) else { raise InvalidHandle }
  guard database.depth < 0x7FFF_FFFF else { raise Overflow }
  @ffi.sqlite3_db_mutex_enter(database.pointer)
  database.depth += 1
}

///|
pub fn HostSqlite::mutex_leave(
  self : HostSqlite,
  mutex : Int64,
) -> Unit raise SqliteError {
  if mutex == self.handles.null_handle {
    return
  }
  guard self.mutexes.get(mutex) is Some(database) else { raise InvalidHandle }
  guard database.depth > 0 else { raise Fault }
  @ffi.sqlite3_db_mutex_leave(database.pointer)
  database.depth -= 1
}
