///|
fn notification_fd(fd : @sqlite_io.Fd) -> @sys.Fd = "%identity"

///|
fn open_job(
  filesystem : @filesystem.HostFs,
  filename : Bytes,
  flags : Int32,
  complete : (Outcome) -> @resource.JobResult,
) -> @resource.Task raise {
  guard database_filename(filesystem, filename, flags) is Some(filename) else {
    return @resource.Task::ready(complete(outcome(14)))
  }
  let code = Ref(0)
  let executor = @ffi.sqlite3_executor_create(code)
  if code.val != 0 {
    return @resource.Task::ready(complete(outcome(code.val)))
  }
  errdefer @ffi.sqlite3_executor_release(executor)
  let native = @ffi.sqlite3_open_job(executor, filename, flags, code)
  if code.val != 0 {
    native.release()
    @ffi.sqlite3_executor_release(executor)
    return @resource.Task::ready(complete(outcome(code.val)))
  }
  let transferred = Ref(false)
  @resource.Task(
    @sys.read_job(notification_fd(native.notification_fd()), 1, -1L),
    publish=() => {
      native.wait()
      let (code, extended, message) = native.result()
      if code != 0 {
        return complete(outcome(code, extended~, message~))
      }
      let pointer = native.take_database()
      transferred.val = true
      let code = install_authorizer(pointer)
      if code != 0 {
        let result = outcome(
          code,
          extended=@ffi.sqlite3_extended_errcode(pointer),
          message=@ffi.sqlite3_errmsg(pointer),
        )
        ignore(@ffi.sqlite3_close(pointer))
        @ffi.sqlite3_executor_release(executor)
        return complete(result)
      }
      complete(
        outcome(0, output=Opened(new_database(pointer, true, executor~))),
      )
    },
    cleanup=() => {
      native.wait()
      if !transferred.val {
        if native.result().0 == 0 {
          native.discard()
        }
        @ffi.sqlite3_executor_release(executor)
      }
      native.release()
    },
  )
}

///|
fn prepare_job(
  database : Database,
  sql : String,
  complete : (Outcome) -> @resource.JobResult,
) -> @resource.Task raise {
  let code = Ref(0)
  let native = @ffi.sqlite3_prepare_job(
    database.executor,
    database.pointer,
    sql,
    code,
  )
  if code.val != 0 {
    native.release()
    return @resource.Task::ready(complete(outcome(code.val)))
  }
  let transferred = Ref(false)
  @resource.Task(
    @sys.read_job(notification_fd(native.notification_fd()), 1, -1L),
    publish=() => {
      native.wait()
      let (code, extended, message, tail) = native.result()
      if code != 0 {
        return complete(outcome(code, extended~, message~, tail~))
      }
      let pointer = native.take_statement()
      transferred.val = true
      complete(
        if @ffi.sqlite3_stmt_is_null(pointer) {
          outcome(0)
        } else {
          outcome(
            0,
            tail~,
            output=Prepared({ pointer, database, leased: false, row: false, }),
          )
        },
      )
    },
    cleanup=() => {
      native.wait()
      if !transferred.val && native.result().0 == 0 {
        native.discard()
      }
      native.release()
    },
  )
}

///|
fn step_job(
  statement : Statement,
  complete : (Outcome) -> @resource.JobResult,
) -> @resource.Task raise {
  let code = Ref(0)
  let database = statement.database
  let native = @ffi.sqlite3_step_job(
    database.executor,
    database.pointer,
    statement.pointer,
    code,
  )
  if code.val != 0 {
    native.release()
    return @resource.Task::ready(complete(outcome(code.val)))
  }
  @resource.Task(
    @sys.read_job(notification_fd(native.notification_fd()), 1, -1L),
    publish=() => {
      native.wait()
      let (code, extended, message, changes) = native.result()
      statement.row = code == 100
      complete({ code, extended, message, changes, tail: -1, output: None, })
    },
    cleanup=() => {
      native.wait()
      native.release()
    },
  )
}

///|
fn cleanup_job(
  database : Database,
  statement : Statement?,
  complete : (Outcome) -> @resource.JobResult,
) -> @resource.Task raise {
  let code = Ref(0)
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
  if code.val != 0 {
    native.release()
    match statement {
      Some(statement) => ignore(@ffi.sqlite3_finalize(statement.pointer))
      None => close_owned(database)
    }
    return @resource.Task::ready(complete(outcome(code.val)))
  }
  @resource.Task(
    @sys.read_job(notification_fd(native.notification_fd()), 1, -1L),
    publish=() => {
      native.wait()
      let (code, extended, message) = native.result()
      complete(outcome(code, extended~, message~))
    },
    cleanup=() => {
      native.wait()
      native.release()
      if statement is None {
        @ffi.sqlite3_executor_release(database.executor)
      }
    },
  )
}
