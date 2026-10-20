///|
async fn main {
  let database = @sqlite3.Connection::open_async(@env.args()[1])
  let create = database.prepare_async(
    "CREATE TABLE entries(id INTEGER UNIQUE, value TEXT, payload BLOB)",
  )
  assert_true(create.step_async() is Done(changes=Some(0L)))
  create.finalize()
  let insert = database.prepare_async("INSERT INTO entries VALUES (?1, ?2, ?3)")
  insert.bind(index=1, 5_000_000_000L)
  insert.bind(index=2, "值😀")
  insert.bind(index=3, b"\x00\xff")
  assert_true(insert.step_async() is Done(changes=Some(1L)))
  insert.reset()
  try insert.step_async() catch {
    @sqlite3.SqliteError(code=Constraint, extended=Some(ConstraintUnique), ..) =>
      ()
    error => raise error
  } noraise {
    _ => fail("expected UNIQUE constraint failure")
  }
  // finalize reports the last step's error, while still destroying the statement.
  insert.finalize() catch {
    @sqlite3.SqliteError(code=Constraint, ..) => ()
    error => raise error
  }
  database.close()
  let database = @sqlite3.Connection::open(@env.args()[1])
  let query = database.prepare("SELECT id, value, payload, NULL FROM entries")
  assert_eq(query.column_count(), 4)
  assert_eq(query.column_name(index=1), "value")
  assert_true(query.step())
  let id : Int64 = query.column(index=0)
  let text : String = query.column(index=1)
  let bytes : Bytes = query.column(index=2)
  let null : @sqlite3.Value = query.column(index=3)
  assert_eq(id, 5_000_000_000L)
  assert_eq(text, "值😀")
  assert_eq(bytes, b"\x00\xff")
  assert_eq(null, @sqlite3.Value::Null)
  assert_eq(query.step(), false)
  query.finalize()
  try database.prepare_async("ATTACH DATABASE ':memory:' AS extra") catch {
    @sqlite3.SqliteError(code=Auth, ..) => ()
    error => raise error
  } noraise {
    _ => fail("ATTACH was not denied")
  }
  try database.prepare_async("PRAGMA temp_store=MEMORY") catch {
    @sqlite3.SqliteError(code=Auth, ..) => ()
    error => raise error
  } noraise {
    _ => fail("PRAGMA was not denied")
  }
  database.close()
  println("sqlite ok")
}
