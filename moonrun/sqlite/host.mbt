///|
pub struct HostSqlite {
  filesystem : @filesystem.HostFs
  handles : @handles.Handles
  databases : Map[Int64, Database]
  statements : Map[Int64, Statement]
  mutexes : Map[Int64, Database]
}

///|
pub struct Database {
  pointer : @ffi.Sqlite3
  executor : @ffi.Sqlite3Executor
  ready : Bool
  mut mutex : Int64?
  mut depth : Int32
  mut leases : Int32
}

///|
pub struct Statement {
  pointer : @ffi.Sqlite3Stmt
  database : Database
  mut leased : Bool
  mut row : Bool
}

///|
pub fn HostSqlite::HostSqlite(
  filesystem : @filesystem.HostFs,
  handles : @handles.Handles,
) -> HostSqlite {
  {
    filesystem,
    handles,
    databases: Map([]),
    statements: Map([]),
    mutexes: Map([]),
  }
}

///|
pub fn HostSqlite::database(
  self : HostSqlite,
  handle : Int64,
) -> Database raise SqliteError {
  guard self.databases.get(handle) is Some(database) else {
    raise InvalidHandle
  }
  database
}

///|
pub fn HostSqlite::statement(
  self : HostSqlite,
  handle : Int64,
) -> Statement raise SqliteError {
  guard self.statements.get(handle) is Some(statement) else {
    raise InvalidHandle
  }
  guard !statement.leased else { raise Fault }
  statement
}

///|
pub fn HostSqlite::release_entered_mutexes(self : HostSqlite) -> Unit {
  for _, database in self.mutexes {
    while database.depth > 0 {
      @ffi.sqlite3_db_mutex_leave(database.pointer)
      database.depth -= 1
    }
  }
}

///|
pub fn HostSqlite::close(self : HostSqlite) -> Unit {
  self.release_entered_mutexes()
  for _, statement in self.statements {
    ignore(@ffi.sqlite3_finalize(statement.pointer))
  }
  self.statements.clear()
  for _, database in self.databases {
    @ffi.sqlite3_executor_release(database.executor)
    ignore(@ffi.sqlite3_close(database.pointer))
  }
  self.databases.clear()
  self.mutexes.clear()
}
