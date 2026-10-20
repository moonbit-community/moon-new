///|
async test "cleanup jobs finalize statements and close databases off thread" {
  let code = Ref(0)
  let executor = @ffi.sqlite3_executor_create(code)
  assert_eq(code.val, 0)
  defer @ffi.sqlite3_executor_release(executor)
  let database = open_database()
  let tail = Ref(0)
  let statement = @ffi.sqlite3_prepare16_v2(database, "SELECT 42", tail, code)
  assert_eq(code.val, 0)
  let finalize = @ffi.sqlite3_finalize_job(executor, database, statement, code)
  defer finalize.release()
  assert_eq(code.val, 0)
  finalize.wait()
  assert_eq(finalize.result(), (0, 0, ""))
  let close = @ffi.sqlite3_close_job(executor, database, code)
  defer close.release()
  assert_eq(code.val, 0)
  close.wait()
  assert_eq(close.result(), (0, 0, ""))
}

///|
async test "a rejected finalizer leaves its statement with the caller" {
  let code = Ref(0)
  let executor = @ffi.sqlite3_executor_create(code)
  assert_eq(code.val, 0)
  defer @ffi.sqlite3_executor_release(executor)
  let database = open_database()
  defer @ffi.sqlite3_close(database) |> ignore
  let other = open_database()
  defer @ffi.sqlite3_close(other) |> ignore
  let tail = Ref(0)
  let statement = @ffi.sqlite3_prepare16_v2(database, "SELECT 42", tail, code)
  defer @ffi.sqlite3_finalize(statement) |> ignore
  assert_eq(code.val, 0)
  let rejected = @ffi.sqlite3_finalize_job(executor, other, statement, code)
  defer rejected.release()
  assert_eq(code.val, 21)
  assert_eq(@ffi.sqlite3_step(statement), 100)
}
