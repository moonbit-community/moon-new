///|
test "legacy inline jobs expose size kind identity and timestamp records" {
  let directory = @sys.tmpdir(prefix="moonrun-legacy-")
  defer @sys.rmdir(directory, recursive=true) |> ignore
  @sys.write_file(directory + "/file", b"abc")
  let source =
    #|(module
    #| (import "moonbitlang/async" "thread_pool/make_open_job" (func $open (param i32 i32 i32 i32 i32 i32 i32) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/run_job" (func $run (param i64)))
    #| (import "moonbitlang/async" "thread_pool/open_job_get_fd" (func $fd (param i64) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/open_job_get_kind" (func $kind (param i64) (result i32)))
    #| (import "moonbitlang/async" "thread_pool/open_job_get_dev_id" (func $dev (param i64) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/open_job_get_file_id" (func $identity (param i64) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/make_file_size_job" (func $size (param i64) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/get_file_size_result" (func $getsize (param i64) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/make_file_time_job" (func $time (param i64) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/get_file_time_result" (func $gettime (param i64 i32)))
    #| (import "moonbitlang/async" "fd_util/sizeof_file_time" (func $timesize (result i32)))
    #| (import "moonbitlang/async" "fd_util/get_mtime_sec" (func $sec (param i32) (result i64)))
    #| (import "moonbitlang/async" "fd_util/get_mtime_nsec" (func $nsec (param i32) (result i32)))
    #| (import "moonbitlang/async" "random/fill" (func $random (param i32 i32) (result i32)))
    #| (memory (export "memory") 1)
    #| (data (i32.const 64) "f\00i\00l\00e\00")
    #| (func (export "_start") (local $job i64) (local $file i64)
    #|   i32.const 64 i32.const 4 i32.const 0 i32.const 0 i32.const 0 i32.const 0 i32.const 0 call $open local.tee $job call $run
    #|   local.get $job call $kind i32.const 1 i32.ne if unreachable end
    #|   local.get $job call $dev drop local.get $job call $identity drop
    #|   local.get $job call $fd local.set $file
    #|   local.get $file call $size local.tee $job call $run
    #|   local.get $job call $getsize i64.const 3 i64.ne if unreachable end
    #|   local.get $file call $time local.tee $job call $run
    #|   call $timesize i32.const 48 i32.ne if unreachable end
    #|   local.get $job i32.const 128 call $gettime
    #|   i32.const 128 call $sec i64.const 0 i64.le_s if unreachable end
    #|   i32.const 128 call $nsec i32.const 1000000000 i32.ge_u if unreachable end
    #|   i32.const 256 i32.const 32 call $random if unreachable end
    #|   i32.const 65536 i32.const 1 call $random i32.const -1 i32.ne if unreachable end))
  assert_eq(compile(source).run(cwd=directory), Completed)
}

///|
test "legacy completion pipes retain their writer after guest handle close" {
  let source =
    #|(module
    #| (import "moonbitlang/async" "fd_util/pipe" (func $pipe (param i32 i32 i32 i32) (result i32)))
    #| (import "moonbitlang/async" "fd_util/close_fd" (func $close (param i64) (result i32)))
    #| (import "moonbitlang/async" "event_bus/create" (func $bus (result i64)))
    #| (import "moonbitlang/async" "event_bus/register" (func $register (param i64 i64 i32) (result i32)))
    #| (import "moonbitlang/async" "event_bus/wait" (func $wait (param i64 i32) (result i32)))
    #| (import "moonbitlang/async" "thread_pool/make_sleep_job" (func $sleep (param i32) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/spawn_worker_with_pipe" (func $spawn (param i32 i64 i64) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/free_worker" (func $free (param i64)))
    #| (import "moonbitlang/async" "io/read/unix" (func $read (param i64 i32 i32 i32) (result i32)))
    #| (memory (export "memory") 1)
    #| (func (export "_start") (local $bus i64) (local $worker i64)
    #|   i32.const 0 i32.const 2 i32.const 1 i32.const 1 call $pipe if unreachable end
    #|   call $bus local.tee $bus i32.const 0 i64.load i32.const 1 call $register if unreachable end
    #|   i32.const 4660 i32.const 10 call $sleep i32.const 8 i64.load call $spawn local.set $worker
    #|   i32.const 8 i64.load call $close if unreachable end
    #|   local.get $bus i32.const 1000 call $wait i32.const 1 i32.lt_s if unreachable end
    #|   i32.const 0 i64.load i32.const 64 i32.const 0 i32.const 4 call $read i32.const 4 i32.ne if unreachable end
    #|   i32.const 64 i32.load i32.const 4660 i32.ne if unreachable end
    #|   local.get $worker call $free))
  if !(@sys.platform is Windows) {
    assert_eq(compile(source).run(), Completed)
  }
}

///|
test "legacy sigwait receives only signals forwarded to its own run" {
  let source =
    #|(module
    #| (import "moonbitlang/async" "thread_pool/make_sigwait_job" (func $signal (param i32 i32) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/run_job" (func $run (param i64)))
    #| (import "moonbitlang/async" "thread_pool/job_get_ret" (func $ret (param i64) (result i32)))
    #| (import "spectest" "print_char" (func $print (param i32)))
    #| (memory (export "memory") 1)
    #| (func (export "_start") (local $job i64)
    #|   i32.const 0 i32.const 15 i32.store
    #|   i32.const 0 i32.const 1 call $signal local.set $job
    #|   i32.const 42 call $print
    #|   local.get $job call $run
    #|   local.get $job call $ret i32.const 15 i32.ne if unreachable end))
  let started = Ref(false)
  let deadline = Ref(0L)
  let sent = Ref(false)
  let control = @runtime.RunControl(poll=() => {
    if started.val && !sent.val && @sys.now() >= deadline.val {
      sent.val = true
      Some(15)
    } else {
      None
    }
  })
  assert_eq(
    compile(source).run(control~, stdout=_ => {
      started.val = true
      deadline.val = @sys.now() + 10L
    }),
    Completed,
  )
  assert_true(sent.val)
}
