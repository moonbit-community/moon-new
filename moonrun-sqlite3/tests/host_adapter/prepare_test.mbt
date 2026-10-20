///|
test "raw preparation preserves tails even without a statement" {
  let database = open_database()
  defer @ffi.sqlite3_close(database) |> ignore
  for
    (sql, expected_tail, empty) in [
      ("SELECT 1; SELECT 2", 9, false),
      ("-- comment\n", 11, true),
      ("", 0, true),
    ] {
    let code = Ref(0)
    let tail = Ref(-1)
    let statement = @ffi.sqlite3_prepare16_v2_raw(database, sql, tail, code)
    defer @ffi.sqlite3_finalize(statement) |> ignore
    assert_eq(code.val, 0)
    assert_eq(tail.val, expected_tail)
    assert_eq(@ffi.sqlite3_stmt_is_null(statement), empty)
  }
}

///|
test "raw preparation reports syntax errors with a null statement" {
  let database = open_database()
  defer @ffi.sqlite3_close(database) |> ignore
  let code = Ref(0)
  let tail = Ref(-1)
  let sql = "SELECT FROM"
  let statement = @ffi.sqlite3_prepare16_v2_raw(database, sql, tail, code)
  defer @ffi.sqlite3_finalize(statement) |> ignore
  assert_eq(code.val, 1)
  assert_true(@ffi.sqlite3_stmt_is_null(statement))
  assert_true(tail.val >= 0 && tail.val <= sql.length())
}
