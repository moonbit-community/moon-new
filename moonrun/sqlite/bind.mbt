///|
pub fn HostSqlite::clear_bindings(
  self : HostSqlite,
  handle : Int64,
) -> Int32 raise SqliteError {
  let statement = self.statement(handle)
  // Active result registers can still refer to the bound text or blob.
  if @ffi.sqlite3_stmt_busy(statement.pointer) {
    return 21
  }
  @ffi.sqlite3_clear_bindings(statement.pointer)
}

///|
pub fn HostSqlite::bind_null(
  self : HostSqlite,
  handle : Int64,
  index : Int32,
) -> Int32 raise SqliteError {
  @ffi.sqlite3_bind_null(self.statement(handle).pointer, index)
}

///|
pub fn HostSqlite::bind_int64(
  self : HostSqlite,
  handle : Int64,
  index : Int32,
  value : Int64,
) -> Int32 raise SqliteError {
  @ffi.sqlite3_bind_int64(self.statement(handle).pointer, index, value)
}

///|
pub fn HostSqlite::bind_double(
  self : HostSqlite,
  handle : Int64,
  index : Int32,
  value : Double,
) -> Int32 raise SqliteError {
  @ffi.sqlite3_bind_double(self.statement(handle).pointer, index, value)
}

///|
pub fn HostSqlite::bind_text(
  self : HostSqlite,
  handle : Int64,
  index : Int32,
  value : String,
) -> Int32 raise SqliteError {
  @ffi.sqlite3_bind_text(self.statement(handle).pointer, index, value)
}

///|
pub fn HostSqlite::bind_blob(
  self : HostSqlite,
  handle : Int64,
  index : Int32,
  value : Bytes,
) -> Int32 raise SqliteError {
  @ffi.sqlite3_bind_blob(self.statement(handle).pointer, index, value)
}
