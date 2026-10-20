///|
fn sqlite_guest(body : String) -> @runtime.Module raise {
  compile(
    (
      #|(module
      #| (import "moonbitlang/sqlite" "sqlite3_null_handle" (func $null (result i64)))
      #| (import "moonbitlang/sqlite" "sqlite3_open_v2" (func $open (param i32 i32 i32 i32 i64) (result i32)))
      #| (import "moonbitlang/sqlite" "sqlite3_close" (func $close (param i64) (result i32)))
      #| (import "moonbitlang/sqlite" "sqlite3_db_mutex" (func $mutex (param i64) (result i64)))
      #| (import "moonbitlang/sqlite" "sqlite3_mutex_enter" (func $enter (param i64)))
      #| (import "moonbitlang/sqlite" "sqlite3_make_open_job" (func $new (param i32 i32 i32) (result i64)))
      #| (import "moonbitlang/sqlite" "sqlite3_job_result" (func $result (param i64 i32)))
      #| (import "moonbitlang/async" "thread_pool/run_job" (func $run (param i64)))
      #| (import "moonbitlang/async" "thread_pool/free_job" (func $free (param i64)))
      #| (import "moonbitlang/async" "thread_pool/spawn_worker_with_pipe" (func $spawn (param i32 i64 i64) (result i64)))
      #| (import "moonbitlang/async" "thread_pool/free_worker" (func $stop (param i64)))
      #| (import "moonbitlang/async" "fd_util/pipe" (func $pipe (param i32 i32 i32 i32) (result i32)))
      #| (import "moonbitlang/async" "fd_util/close_fd" (func $close_fd (param i64) (result i32)))
      #| (memory (export "memory") 1)
      #| (data (i32.const 16) ":memory:")
      #| (func (export "_start") (local $db i64) (local $job i64) (local $worker i64)
      #|   BODY))
    ).replace(old="BODY", new=body),
  )
}

///|
async test "SQLite releases unclaimed results when the common job is freed" {
  let program = sqlite_guest(
    (
      #|i32.const 16 i32.const 8 i32.const 6 call $new local.set $job
      #|local.get $job call $run
      #|local.get $job i32.const 64 call $result
      #|i32.const 64 i32.load if unreachable end
      #|local.get $job call $free
    ),
  )
  assert_eq(program.run(env={ "MOONBIT_ASYNC_CHECK_FD_LEAK": "1" }), Completed)
}

///|
async test "SQLite in-flight jobs and workers can be released before completion" {
  let program = sqlite_guest(
    (
      #|i32.const 64 i32.const 2 i32.const 1 i32.const 1 call $pipe if unreachable end
      #|i32.const 16 i32.const 8 i32.const 6 call $new local.set $job
      #|i32.const 1 local.get $job i32.const 72 i64.load call $spawn local.set $worker
      #|local.get $job call $free
      #|local.get $worker call $stop
      #|i32.const 64 i64.load call $close_fd if unreachable end
      #|i32.const 72 i64.load call $close_fd if unreachable end
    ),
  )
  for _ in 0..<5 {
    assert_eq(
      @async.with_timeout(5000, () => {
        program.run(env={ "MOONBIT_ASYNC_CHECK_FD_LEAK": "1" })
      }),
      Completed,
    )
  }
}

///|
async test "SQLite ABI errors identify the operation and validate output ranges" {
  for
    (body, expected) in [
      (
        "i64.const 0 i32.const 64 call $result", "sqlite3_job_result failed: InvalidHandle",
      ),
      ("i64.const 0 call $close drop", "sqlite3_close failed: InvalidHandle"),
      (
        "i32.const 16 i32.const 8 i32.const 0 i32.const 6 call $null call $open drop",
        "sqlite3_open_v2 failed: Fault",
      ),
      (
        "i32.const 16 i32.const 8 i32.const 65532 i32.const 6 call $null call $open drop",
        "sqlite3_open_v2 failed: Fault",
      ),
    ] {
    guard sqlite_guest(body).run() is Trapped(message) else {
      fail("accepted an invalid SQLite ABI call")
    }
    assert_true(message.contains(expected), msg=message)
  }
}

///|
async test "SQLite entered mutexes are released when a guest traps" {
  let program = sqlite_guest(
    (
      #|i32.const 16 i32.const 8 i32.const 64 i32.const 6 call $null call $open if unreachable end
      #|i32.const 64 i64.load local.tee $db call $mutex call $enter
      #|unreachable
    ),
  )
  assert_true(
    @async.with_timeout(5000, () => program.run(env={})) is Trapped(_),
  )
  assert_true(
    @async.with_timeout(5000, () => program.run(env={})) is Trapped(_),
  )
}
