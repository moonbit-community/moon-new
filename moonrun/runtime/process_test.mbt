///|
async test "ambient guest can query and signal a process created outside its run" {
  let windows = @sys.platform is Windows
  let pid = if windows {
    @native_process.spawn_orphan("cmd", ["/d", "/c", "ping -n 6 127.0.0.1 >nul"])
  } else {
    @native_process.spawn_orphan("/bin/sh", ["-c", "exec sleep 5"])
  }
  let mut reaped = false
  defer (if !reaped { ignore(@native_process.wait_pid(pid)) })
  let source =
    #|(module
    #| (import "moonbitlang/async" "process/open_pid_handle" (func $open (param i32) (result i64)))
    #| (import "moonbitlang/async" "fd_util/invalid_fd" (func $invalid (result i64)))
    #| (import "moonbitlang/async" "process/get_process_result" (func $result (param i64 i32 i32) (result i32)))
    #| (import "moonbitlang/async" "process/kill" (func $kill (param i32)))
    #| (import "moonbitlang/async" "os_error/get_errno" (func $errno (result i32)))
    #| (import "moonbitlang/async" "thread_pool/make_sleep_job" (func $sleep (param i32) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/run_job" (func $run (param i64)))
    #| (import "moonbitlang/async" "fd_util/close_fd" (func $close (param i64) (result i32)))
    #| (memory (export "memory") 1)
    #| (func (export "_start") (local $handle i64)
    #|   i32.const PID call $open local.set $handle
    #|   local.get $handle i32.const PID i32.const 0 call $result i32.const -1 i32.ne if unreachable end
    #|   call $errno i32.const PENDING i32.ne if unreachable end
    #|   i32.const PID call $kill
    #|   loop $wait
    #|     local.get $handle i32.const PID i32.const 0 call $result
    #|     if i32.const 1 call $sleep call $run br $wait end
    #|   end
    #|   i32.const 0 i32.load i32.const STATUS i32.ne if unreachable end
    #|   local.get $handle call $invalid i64.ne if local.get $handle call $close if unreachable end end))
  let program = compile(
    source
    .split("PID")
    .join(pid.to_string())
    .replace(
      old="PENDING",
      new=if windows {
        "997"
      } else if @sys.platform is MacOS {
        "35"
      } else {
        "11"
      },
    )
    .replace(old="STATUS", new=if windows { "1" } else { "-9" }),
  )
  assert_eq(program.run(control=cancel_after(3000)), Completed)
  reaped = true
}

///|
test "policy denies opening a process not created by the guest" {
  let source =
    #|(module
    #| (import "moonbitlang/async" "process/open_pid_handle" (func $open (param i32) (result i64)))
    #| (import "moonbitlang/async" "fd_util/invalid_fd" (func $invalid (result i64)))
    #| (import "moonbitlang/async" "os_error/get_errno" (func $errno (result i32)))
    #| (func (export "_start")
    #|   i32.const 1 call $open call $invalid i64.ne if unreachable end
    #|   call $errno i32.const PERMISSION i32.ne if unreachable end))
  let policy = @runtime.Policy::from_json("{}")
  assert_eq(
    compile(
      source.replace(
        old="PERMISSION",
        new=if @sys.platform is Windows { "5" } else { "13" },
      ),
    ).run(policy~),
    Completed,
  )
}

///|
test "legacy spawn merges overrides and ignores initialized invalid environment entries" {
  if @sys.platform is Windows {
    return
  }
  let source =
    #|(module
    #| (import "moonbitlang/async" "process/allocate_env_block" (func $env (param i32) (result i64)))
    #| (import "moonbitlang/async" "fd_util/invalid_fd" (func $invalid (result i64)))
    #| (import "moonbitlang/async" "process/env_block_add_entry" (func $entry (param i64 i32 i32 i32 i32 i32)))
    #| (import "moonbitlang/async" "process/make_argv_array/unix" (func $argv (param i32) (result i64)))
    #| (import "moonbitlang/async" "process/argv_array_add_entry/unix" (func $arg (param i64 i32 i32 i32)))
    #| (import "moonbitlang/async" "thread_pool/make_spawn_job/unix" (func $spawn (param i32 i32 i64 i64 i32 i64 i64 i64 i32 i32 i32) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/run_job" (func $run (param i64)))
    #| (import "moonbitlang/async" "thread_pool/job_get_ret" (func $ret (param i64) (result i32)))
    #| (import "moonbitlang/async" "process/get_process_result" (func $result (param i64 i32 i32) (result i32)))
    #| (import "moonbitlang/async" "thread_pool/make_sleep_job" (func $sleep (param i32) (result i64)))
    #| (memory (export "memory") 1)
    #| (data (i32.const 0) "/\00b\00i\00n\00/\00s\00h\00")
    #| (data (i32.const 32) "s\00h\00")
    #| (data (i32.const 64) "-\00c\00")
    #| (data (i32.const 96) "e\00x\00i\00t\00 \00\22\00$\00X\00\22\00")
    #| (data (i32.const 160) "X\00")
    #| (data (i32.const 176) "1\007\00")
    #| (data (i32.const 192) "2\003\00\00\00s\00u\00f\00f\00i\00x\00")
    #| (data (i32.const 224) "B\00A\00D\00\00\00K\00E\00Y\00")
    #| (func (export "_start") (local $env i64) (local $argv i64) (local $job i64) (local $pid i32)
    #|   i32.const 3 call $env local.set $env
    #|   local.get $env i32.const 0 i32.const 160 i32.const 1 i32.const 176 i32.const 2 call $entry
    #|   local.get $env i32.const 1 i32.const 224 i32.const 7 i32.const 176 i32.const 2 call $entry
    #|   local.get $env i32.const 2 i32.const 160 i32.const 1 i32.const 192 i32.const 9 call $entry
    #|   i32.const 3 call $argv local.set $argv
    #|   local.get $argv i32.const 0 i32.const 32 i32.const 2 call $arg
    #|   local.get $argv i32.const 1 i32.const 64 i32.const 2 call $arg
    #|   local.get $argv i32.const 2 i32.const 96 i32.const 9 call $arg
    #|   i32.const 0 i32.const 7 local.get $argv local.get $env i32.const 1
    #|   call $invalid call $invalid call $invalid i32.const 0 i32.const 0 i32.const 0 call $spawn
    #|   local.tee $job call $run local.get $job call $ret local.set $pid
    #|   loop $wait
    #|     call $invalid local.get $pid i32.const 256 call $result
    #|     if i32.const 1 call $sleep call $run br $wait end
    #|   end
    #|   i32.const 256 i32.load i32.const 23 i32.ne if unreachable end))
  assert_eq(compile(source).run(control=cancel_after(3000)), Completed)
}

///|
test "current and legacy spawn result handle imports return null before publication" {
  let source =
    #|(module
    #| (import "moonbitlang/sqlite" "sqlite3_null_handle" (func $null (result i64)))
    #| (import "moonbitlang/async" "thread_pool/spawn_job_get_result_handle" (func $current (param i64) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/get_spawn_job_result_handle" (func $legacy (param i64 i32) (result i64)))
    #| (func (export "_start")
    #|   i64.const 0 call $current call $null i64.ne if unreachable end
    #|   i64.const 0 i32.const 0 call $legacy call $null i64.ne if unreachable end))
  assert_eq(compile(source).run(), Completed)
}

///|
test "macOS PID fallback clears stale errno" {
  if !(@sys.platform is MacOS) {
    return
  }
  let source =
    #|(module
    #| (import "moonbitlang/async" "process/get_process_result" (func $result (param i64 i32 i32) (result i32)))
    #| (import "moonbitlang/async" "process/open_pid_handle" (func $open (param i32) (result i64)))
    #| (import "moonbitlang/async" "fd_util/invalid_fd" (func $invalid (result i64)))
    #| (import "moonbitlang/async" "os_error/get_errno" (func $errno (result i32)))
    #| (memory (export "memory") 1)
    #| (func (export "_start")
    #|   i64.const 0 i32.const 1 i32.const 0 call $result i32.const -1 i32.ne if unreachable end
    #|   call $errno i32.const 9 i32.ne if unreachable end
    #|   i32.const 1 call $open call $invalid i64.ne if unreachable end
    #|   call $errno if unreachable end))
  assert_eq(compile(source).run(), Completed)
}
// Compatibility regressions; original probes from moon/crates/moonrun/tests at 12e9d22e.

///|
test "process result distinguishes null and reserved invalid handles" {
  if @sys.platform is Windows {
    return
  }
  let source =
    #|(module
    #|                    (import "moonbitlang/async" "process/get_process_result"
    #|                        (func $result (param i64 i32 i32) (result i32)))
    #|                    (import "moonbitlang/async" "fd_util/invalid_fd"
    #|                        (func $invalid (result i64)))
    #|                    (import "moonbitlang/async" "os_error/get_errno"
    #|                        (func $errno (result i32)))
    #|                    (memory (export "memory") 1)
    #|                    (func (export "_start")
    #|                        (if (i32.ne (call $result (i64.const 0) (i32.const 97841) (i32.const 0))
    #|                                    (i32.const -1)) (then unreachable))
    #|                        (if (i32.ne (call $errno) (i32.const 9)) (then unreachable))
    #|                        (if (i32.ne (call $result (call $invalid) (i32.const 97841) (i32.const 0))
    #|                                    (i32.const -1)) (then unreachable))
    #|                        (if (i32.ne (call $errno) (i32.const 10)) (then unreachable))))
  assert_eq(compile(source).run(), Completed)
}

///|
test "spawn rejects zero stdio instead of treating it as the invalid-fd sentinel" {
  if @sys.platform is Windows {
    return
  }
  let source =
    #|(module
    #| (import "moonbitlang/async" "process/make_argv_array/unix" (func $argv (param i32) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/spawn_job/unix" (func $spawn (param i32 i32 i64 i64 i64 i64 i64) (result i64)))
    #| (import "moonbitlang/async" "process/make_env" (func $env (param i32) (result i64)))
    #| (import "moonbitlang/async" "fd_util/invalid_fd" (func $invalid (result i64)))
    #| (memory (export "memory") 1)
    #| (func (export "_start")
    #|   i32.const 0 i32.const 0 i32.const 0 call $argv i32.const 0 call $env STDIO
    #|   call $spawn drop))
  for
    handles in [
      "i64.const 0 call $invalid call $invalid", "call $invalid i64.const 0 call $invalid",
      "call $invalid call $invalid i64.const 0",
    ] {
    guard compile(source.replace(old="STDIO", new=handles)).run()
      is Trapped(message) else {
      fail("spawn accepted a null descriptor")
    }
    assert_true(message.contains("Badf"))
  }
}
