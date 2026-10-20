///|
fn HostSqlite::column(
  self : HostSqlite,
  handle : Int64,
  index : Int32,
  row : Bool,
) -> Statement raise SqliteError {
  let statement = self.statement(handle)
  guard index >= 0 &&
    index < @ffi.sqlite3_column_count(statement.pointer) &&
    (!row || statement.row) else {
    raise Fault
  }
  statement
}

///|
pub fn HostSqlite::column_count(
  self : HostSqlite,
  handle : Int64,
) -> Int32 raise SqliteError {
  @ffi.sqlite3_column_count(self.statement(handle).pointer)
}

///|
pub fn HostSqlite::column_name(
  self : HostSqlite,
  handle : Int64,
  index : Int32,
) -> String? raise SqliteError {
  @ffi.sqlite3_column_name(self.column(handle, index, false).pointer, index)
}

///|
pub fn HostSqlite::column_type(
  self : HostSqlite,
  handle : Int64,
  index : Int32,
) -> Int32 raise SqliteError {
  @ffi.sqlite3_column_type(self.column(handle, index, true).pointer, index)
}

///|
pub fn HostSqlite::column_int64(
  self : HostSqlite,
  handle : Int64,
  index : Int32,
) -> Int64 raise SqliteError {
  @ffi.sqlite3_column_int64(self.column(handle, index, true).pointer, index)
}

///|
pub fn HostSqlite::column_double(
  self : HostSqlite,
  handle : Int64,
  index : Int32,
) -> Double raise SqliteError {
  @ffi.sqlite3_column_double(self.column(handle, index, true).pointer, index)
}

///|
pub fn HostSqlite::column_text(
  self : HostSqlite,
  handle : Int64,
  index : Int32,
) -> String raise SqliteError {
  let statement = self.column(handle, index, true)
  let code = Ref(0)
  @ffi.sqlite3_column_text(
    statement.database.pointer,
    statement.pointer,
    index,
    code,
  )
}

///|
pub fn HostSqlite::column_blob(
  self : HostSqlite,
  handle : Int64,
  index : Int32,
) -> Bytes raise SqliteError {
  let statement = self.column(handle, index, true)
  let code = Ref(0)
  @ffi.sqlite3_column_blob(
    statement.database.pointer,
    statement.pointer,
    index,
    code,
  )
}
