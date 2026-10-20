///|
async fn open_job(
  filesystem : @filesystem.HostFs,
  filename : Bytes,
  flags : Int32,
) -> Outcome {
  guard database_filename(filesystem, filename, flags) is Some(filename) else {
    return outcome(14)
  }
  let code = Ref(0)
  let executor = @ffi.sqlite3_executor_create(code)
  if code.val != 0 {
    return outcome(code.val)
  }
  errdefer @ffi.sqlite3_executor_release(executor)
  let native = @ffi.sqlite3_open_job(executor, filename, flags, code)
  defer native.release()
  if code.val != 0 {
    @ffi.sqlite3_executor_release(executor)
    return outcome(code.val)
  }
  native.wait()
  let (code, extended, message) = native.result()
  if code != 0 {
    @ffi.sqlite3_executor_release(executor)
    return outcome(code, extended~, message~)
  }
  let pointer = native.take_database()
  let code = install_authorizer(pointer)
  if code != 0 {
    let result = outcome(
      code,
      extended=@ffi.sqlite3_extended_errcode(pointer),
      message=@ffi.sqlite3_errmsg(pointer),
    )
    ignore(@ffi.sqlite3_close(pointer))
    @ffi.sqlite3_executor_release(executor)
    return result
  }
  outcome(0, output=Opened(new_database(pointer, true, executor~)))
}

///|
async fn prepare_job(database : Database, sql : String) -> Outcome {
  let code = Ref(0)
  let native = @ffi.sqlite3_prepare_job(
    database.executor,
    database.pointer,
    sql,
    code,
  )
  defer native.release()
  if code.val != 0 {
    return outcome(code.val)
  }
  native.wait()
  let (code, extended, message, tail) = native.result()
  if code != 0 {
    return outcome(code, extended~, message~, tail~)
  }
  let pointer = native.take_statement()
  if @ffi.sqlite3_stmt_is_null(pointer) {
    return outcome(0)
  }
  outcome(
    0,
    tail~,
    output=Prepared({ pointer, database, leased: false, row: false, }),
  )
}

///|
async fn step_job(statement : Statement) -> Outcome {
  let code = Ref(0)
  let database = statement.database
  let native = @ffi.sqlite3_step_job(
    database.executor,
    database.pointer,
    statement.pointer,
    code,
  )
  defer native.release()
  if code.val != 0 {
    return outcome(code.val)
  }
  native.wait()
  let (code, extended, message, changes) = native.result()
  statement.row = code == 100
  { code, extended, message, changes, tail: -1, output: None, }
}

///|
fn cleanup_fallback(database : Database, statement : Statement?) -> Unit {
  match statement {
    Some(statement) => ignore(@ffi.sqlite3_finalize(statement.pointer))
    None => close_owned(database)
  }
}

///|
async fn cleanup_job(database : Database, statement : Statement?) -> Outcome {
  let code = Ref(0)
  errdefer cleanup_fallback(database, statement)
  let native = match statement {
    Some(statement) =>
      @ffi.sqlite3_finalize_job(
        database.executor,
        database.pointer,
        statement.pointer,
        code,
      )
    None => @ffi.sqlite3_close_job(database.executor, database.pointer, code)
  }
  defer native.release()
  if code.val != 0 {
    cleanup_fallback(database, statement)
    return outcome(code.val)
  }
  native.wait()
  let (code, extended, message) = native.result()
  if statement is None {
    @ffi.sqlite3_executor_release(database.executor)
  }
  outcome(code, extended~, message~)
}
