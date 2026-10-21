///|
fn test_host() -> @sqlite.HostSqlite {
  let filesystem = @filesystem.HostFs(
    None,
    @env.current_dir().unwrap_or("."),
    @stdio.Stdio(None, None, None),
    Map([]),
  )
  @sqlite.HostSqlite(filesystem, @handles.Handles())
}

///|
test "jobs pin databases and statements until their handles are released" {
  let host = test_host()
  defer host.close()
  let (code, database) = host.open_v2(b":memory:", 6, host.handles.null_handle)
  assert_eq(code, 0)
  let prepare = host.make_prepare_job(database, "SELECT 42")
  try host.close_database(database) catch {
    @sqlite.Fault => ()
    error => raise error
  } noraise {
    _ => fail("closed a pinned database")
  }
  assert_eq(prepare.prepare().run().ret, 0)
  let statement = host.take_job_handle(prepare)
  try host.take_job_handle(prepare) catch {
    @sqlite.Fault => ()
    error => raise error
  } noraise {
    _ => fail("transferred a statement twice")
  }
  prepare.close()
  let step = host.make_step_job(database, statement)
  try host.finalize(statement) catch {
    @sqlite.Fault => ()
    error => raise error
  } noraise {
    _ => fail("finalized a pinned statement")
  }
  assert_eq(step.prepare().run().ret, 100)
  try host.column_int64(statement, 0) catch {
    @sqlite.Fault => ()
    error => raise error
  } noraise {
    _ => fail("accessed a pinned statement")
  }
  step.close()
  assert_eq(host.column_int64(statement, 0), 42L)
  let finalize = host.make_finalize_job(database, statement)
  try host.step(statement) catch {
    @sqlite.InvalidHandle => ()
    error => raise error
  } noraise {
    _ => fail("reused a consumed statement")
  }
  // An unsubmitted finalizer must still destroy its owned statement.
  finalize.close()
  assert_eq(host.close_database(database), 0)
}

///|
test "discard retains a prepare lease after the source job is freed" {
  let host = test_host()
  defer host.close()
  let (_, database) = host.open_v2(b":memory:", 6, host.handles.null_handle)
  let prepare = host.make_prepare_job(database, "SELECT 1")
  assert_eq(prepare.prepare().run().ret, 0)
  guard prepare.discard() is Some(discard) else { fail("missing discard job") }
  assert_true(prepare.discard() is None)
  prepare.close()
  try host.close_database(database) catch {
    @sqlite.Fault => ()
    error => raise error
  } noraise {
    _ => fail("discard lost its database lease")
  }
  assert_eq(discard.prepare().run().ret, 0)
  discard.close()
  assert_eq(host.close_database(database), 0)
}

///|
test "invalid finalizers preserve the original statement and database" {
  let host = test_host()
  defer host.close()
  let (_, database) = host.open_v2(b":memory:", 6, host.handles.null_handle)
  let (_, other) = host.open_v2(b":memory:", 6, host.handles.null_handle)
  let (_, statement, _) = host.prepare(database, "SELECT 42")
  try host.make_finalize_job(other, statement) catch {
    @sqlite.Fault => ()
    error => raise error
  } noraise {
    _ => fail("accepted a statement from another database")
  }
  assert_eq(host.step(statement), 100)
  assert_eq(host.finalize(statement), 0)
  assert_eq(host.close_database(database), 0)
  assert_eq(host.close_database(other), 0)
}

///|
test "busy statements keep their text and blob bindings until reset" {
  let host = test_host()
  defer host.close()
  let (_, database) = host.open_v2(b":memory:", 6, host.handles.null_handle)
  let (_, statement, _) = host.prepare(database, "SELECT ?1, ?2")
  assert_eq(host.bind_text(statement, 1, "值😀"), 0)
  assert_eq(host.bind_blob(statement, 2, b"\x00\xff"), 0)
  assert_eq(host.step(statement), 100)
  assert_eq(host.clear_bindings(statement), 21)
  assert_eq(host.column_text(statement, 0), "值😀")
  assert_eq(host.column_blob(statement, 1), b"\x00\xff")
  assert_eq(host.reset(statement), 0)
  assert_eq(host.clear_bindings(statement), 0)
  assert_eq(host.step(statement), 100)
  assert_eq(host.column_type(statement, 0), 5)
  assert_eq(host.finalize(statement), 0)
  assert_eq(host.close_database(database), 0)
}

///|
test "bundled SQLite version and default foreign keys match moonrun" {
  let host = test_host()
  defer host.close()
  let (_, database) = host.open_v2(b":memory:", 6, host.handles.null_handle)
  let (_, version, _) = host.prepare(
    database, "SELECT sqlite_version(), soundex('MoonBit')",
  )
  assert_eq(host.step(version), 100)
  assert_eq(host.column_text(version, 0), "3.53.2")
  assert_eq(host.column_text(version, 1), "M513")
  assert_eq(host.finalize(version), 0)
  for
    sql in [
      "CREATE TABLE parent(id PRIMARY KEY)", "CREATE TABLE child(id REFERENCES parent(id))",
    ] {
    let (_, statement, _) = host.prepare(database, sql)
    assert_eq(host.step(statement), 101)
    assert_eq(host.finalize(statement), 0)
  }
  let (_, insert, _) = host.prepare(database, "INSERT INTO child VALUES(42)")
  assert_eq(host.step(insert), 19)
  assert_eq(host.errcode(database, true), 787)
  assert_eq(host.finalize(insert), 19)
  assert_eq(host.close_database(database), 0)
}
