///|
async test "guest worker completion is delivered through its own event bus" {
  let source =
    #|(module
    #| (import "moonbitlang/async" "event_bus/create" (func $bus (result i64)))
    #| (import "moonbitlang/async" "event_bus/wait" (func $wait (param i64 i32) (result i32)))
    #| (import "moonbitlang/async" "thread_pool/init_thread_pool" (func $init (param i64) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/make_sleep_job" (func $sleep (param i32) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/spawn_worker" (func $spawn (param i32 i64) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/cancel_worker_with_retry" (func $status (param i64) (result i32)))
    #| (import "moonbitlang/async" "thread_pool/job_get_ret" (func $ret (param i64) (result i32)))
    #| (import "moonbitlang/async" "thread_pool/fetch_completion/unix" (func $fetch (param i64 i32 i32) (result i32)))
    #| (import "moonbitlang/async" "event_bus/get_event" (func $event (param i64 i32) (result i64)))
    #| (import "moonbitlang/async" "event_bus/event_bytes_transferred/windows" (func $bytes (param i64) (result i32)))
    #| (memory (export "memory") 1)
    #| (func (export "_start") (local $bus i64) (local $source i64) (local $job i64) (local $worker i64)
    #|   call $bus local.tee $bus call $init local.set $source
    #|   i32.const 10 call $sleep local.set $job
    #|   i32.const 42 local.get $job call $spawn local.set $worker
    #|   local.get $bus i32.const 1000 call $wait
    #|   i32.const 1 i32.lt_s if unreachable end
    #|   COMPLETION
    #|   local.get $worker call $status i32.const 2 i32.ne if unreachable end
    #|   local.get $job call $ret if unreachable end))
  let program = compile(
    source.replace(
      old="COMPLETION",
      new=if @async.platform is Windows {
        "local.get $bus i32.const 0 call $event call $bytes i32.const 42 i32.ne if unreachable end"
      } else {
        "local.get $source i32.const 0 i32.const 1 call $fetch i32.const 4 i32.ne if unreachable end i32.const 0 i32.load i32.const 42 i32.ne if unreachable end"
      },
    ),
  )
  assert_eq(@async.all([() => program.run(), () => program.run()]), [
    Completed,
    Completed,
  ])
}

///|
async test "file jobs retain resources and own buffers across memory growth" {
  let directory = @fs.tmpdir(prefix="moonrun-worker-")
  defer @fs.rmdir(directory, recursive=true) |> ignore
  let source =
    #|(module
    #| (import "moonbitlang/async" "event_bus/create" (func $bus (result i64)))
    #| (import "moonbitlang/async" "event_bus/wait" (func $wait (param i64 i32) (result i32)))
    #| (import "moonbitlang/async" "thread_pool/init_thread_pool" (func $init (param i64) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/spawn_worker" (func $spawn (param i32 i64) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/job_get_ret" (func $ret (param i64) (result i32)))
    #| (import "moonbitlang/async" "thread_pool/free_job" (func $free (param i64)))
    #| (import "moonbitlang/async" "thread_pool/free_worker" (func $freeworker (param i64)))
    #| (import "moonbitlang/async" "thread_pool/fetch_completion/unix" (func $fetch (param i64 i32 i32) (result i32)))
    #| (import "moonbitlang/async" "thread_pool/make_open_stat_job" (func $open (param i32 i32 i32 i32 i32 i32 i32 i32 i32) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/get_stat_result" (func $stat (param i64 i32 i32)))
    #| (import "moonbitlang/async" "thread_pool/open_job_get_fd" (func $fd (param i64) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/make_read_job" (func $read (param i64 i32 i64) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/make_write_job" (func $write (param i64 i32 i32 i32 i64) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/get_read_result" (func $copy (param i64 i32 i32 i32)))
    #| (import "moonbitlang/async" "fd_util/close_fd" (func $close (param i64) (result i32)))
    #| (memory (export "memory") 1)
    #| (data (i32.const 64) "f\00i\00l\00e\00")
    #| (data (i32.const 128) "hello")
    #| (global $bus (mut i64) i64.const 0)
    #| (global $source (mut i64) i64.const 0)
    #| (func $run (param $job i64) (result i32) (local $worker i64)
    #|   i32.const 7 local.get $job call $spawn local.set $worker
    #|   global.get $bus i32.const 5000 call $wait i32.eqz if unreachable end
    #|   FETCH
    #|   local.get $worker call $freeworker
    #|   local.get $job call $ret)
    #| (func (export "_start") (local $open i64) (local $fd i64) (local $read i64) (local $write i64)
    #|   call $bus global.set $bus
    #|   global.get $bus call $init global.set $source
    #|   i32.const 64 i32.const 4 i32.const 2 i32.const 4 i32.const 0 i32.const 0 i32.const 420 i32.const 3 i32.const 24
    #|   call $open local.tee $open call $run if unreachable end
    #|   local.get $open i32.const 16 i32.const 24 call $stat
    #|   i32.const 16 i32.load i32.const 24 i32.ne if unreachable end
    #|   i32.const 24 i64.load i64.const 1 i64.ne if unreachable end
    #|   local.get $open call $fd local.set $fd
    #|   local.get $open call $free
    #|   local.get $fd i32.const 128 i32.const 0 i32.const 5 i64.const 0 call $write local.set $write
    #|   local.get $fd i32.const 5 i64.const 0 call $read local.set $read
    #|   local.get $fd call $close if unreachable end
    #|   i32.const 128 i32.const 120 i32.store8
    #|   i32.const 1 memory.grow drop
    #|   local.get $write call $run i32.const 5 i32.ne if unreachable end
    #|   local.get $write call $free
    #|   local.get $read call $run i32.const 5 i32.ne if unreachable end
    #|   local.get $read i32.const 65536 i32.const 3 i32.const 5 call $copy
    #|   i32.const 65539 i32.load8_u i32.const 104 i32.ne if unreachable end
    #|   local.get $read call $free))
  let program = compile(
    source.replace(
      old="FETCH",
      new=if @async.platform is Windows {
        ""
      } else {
        "global.get $source i32.const 0 i32.const 32 call $fetch drop"
      },
    ),
  )
  assert_eq(program.run(cwd=directory), Completed)
  assert_eq(@fs.read_file(directory + "/file").binary(), b"hello")
}

///|
async test "standard stream file kind uses the native stat output" {
  let program = compile(
    (
      #|(module
      #| (import "moonbitlang/async" "stdio/get_stdio_handle" (func $stdout (param i32) (result i64)))
      #| (import "moonbitlang/async" "fd_util/kind_of_fd" (func $kind (param i64) (result i32)))
      #| (func (export "_start")
      #|   i32.const 1 call $stdout call $kind i32.const 0 i32.lt_s if unreachable end))
    ),
  )
  assert_eq(program.run(), Completed)
}

///|
async test "embedding forwards guest signals without terminating the host" {
  let source =
    #|(module
    #| (import "moonbitlang/async" "event_bus/create" (func $bus (result i64)))
    #| (import "moonbitlang/async" "event_bus/wait" (func $wait (param i64 i32) (result i32)))
    #| (import "moonbitlang/async" "thread_pool/init_thread_pool" (func $pool (param i64) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/fetch_completion/unix" (func $fetch (param i64 i32 i32) (result i32)))
    #| (import "moonbitlang/async" "event_bus/get_event" (func $event (param i64 i32) (result i64)))
    #| (import "moonbitlang/async" "event_bus/event_bytes_transferred/windows" (func $bytes (param i64) (result i32)))
    #| (import "moonbitlang/async" "signal/get_signal_by_index" (func $signal (param i32) (result i32)))
    #| (import "moonbitlang/async" "signal/set_global_cancellation_signals" (func $configure (param i32 i32 i32 i32)))
    #| (import "moonbitlang/async" "signal/start_signal_handler" (func $start))
    #| (import "moonbitlang/async" "runtime/terminate_process_by_signal" (func $terminate (param i32)))
    #| (import "spectest" "print_char" (func $ready (param i32)))
    #| (memory (export "memory") 1)
    #| (func (export "_start") (local $bus i64) (local $pool i64)
    #|   call $bus local.tee $bus call $pool local.set $pool
    #|   i32.const 0 i32.const 0 call $signal i32.store
    #|   i32.const 0 i32.const 1 i32.const 0 i32.const 1 call $configure
    #|   call $start
    #|   i32.const 42 call $ready
    #|   local.get $bus i32.const 5000 call $wait i32.eqz if unreachable end
    #|   COMPLETION
    #|   i32.const 0 i32.load i32.const -2147483648 i32.or i32.ne if unreachable end
    #|   i32.const 0 i32.load call $terminate))
  let program = compile(
    source.replace(
      old="COMPLETION",
      new=if @async.platform is Windows {
        "local.get $bus i32.const 0 call $event call $bytes"
      } else {
        "local.get $pool i32.const 16 i32.const 1 call $fetch i32.const 4 i32.ne if unreachable end i32.const 16 i32.load"
      },
    ),
  )
  let control = @runtime.RunControl()
  let started = Ref(false)
  let ready = @cond_var.Cond()
  let signal = @signal.Signal::SIGINT.to_int()
  assert_false(control.send_signal(signal))
  @async.with_task_group(group => {
    let run = group.spawn(() => {
      program.run(control~, stdout=bytes => {
        if bytes == b"*" {
          started.val = true
          ready.signal()
        }
      })
    })
    while !started.val {
      ready.wait()
    }
    assert_false(control.send_signal(-1))
    assert_true(control.send_signal(signal))
    assert_eq(run.wait(), Signaled(signal))
  })
  assert_false(control.send_signal(signal))
}

///|
async test "Windows I/O completion retains input across memory growth and handle close" {
  if !(@async.platform is Windows) {
    return
  }
  let source =
    #|(module
    #| (import "moonbitlang/async" "event_bus/create" (func $bus (result i64)))
    #| (import "moonbitlang/async" "event_bus/try_register" (func $register (param i64 i64 i32) (result i32)))
    #| (import "moonbitlang/async" "event_bus/wait" (func $wait (param i64 i32) (result i32)))
    #| (import "moonbitlang/async" "event_bus/get_event" (func $event (param i64 i32) (result i64)))
    #| (import "moonbitlang/async" "event_bus/event_io_result/windows" (func $token (param i64) (result i64)))
    #| (import "moonbitlang/async" "fd_util/pipe" (func $pipe (param i32 i32 i32 i32) (result i32)))
    #| (import "moonbitlang/async" "fd_util/close_fd" (func $close (param i64) (result i32)))
    #| (import "moonbitlang/async" "io/make_file_write_io_result/windows" (func $makewrite (param i32 i32 i32 i64) (result i64)))
    #| (import "moonbitlang/async" "io/make_file_read_io_result/windows" (func $makeread (param i32 i64) (result i64)))
    #| (import "moonbitlang/async" "io/write/windows" (func $write (param i64 i64) (result i32)))
    #| (import "moonbitlang/async" "io/read/windows" (func $read (param i64 i64) (result i32)))
    #| (import "moonbitlang/async" "io/io_result_get_status/windows" (func $status (param i64 i64) (result i32)))
    #| (import "moonbitlang/async" "io/io_result_copy_read/windows" (func $copy (param i64 i32 i32 i32)))
    #| (import "moonbitlang/async" "io/free_io_result/windows" (func $free (param i64)))
    #| (memory (export "memory") 1)
    #| (data (i32.const 32) "hello")
    #| (func (export "_start") (local $bus i64) (local $reader i64) (local $writer i64) (local $read i64) (local $write i64) (local $token i64) (local $completed i32) (local $count i32) (local $index i32)
    #|   call $bus local.set $bus
    #|   i32.const 0 i32.const 2 i32.const 1 i32.const 1 call $pipe if unreachable end
    #|   i32.const 0 i64.load local.set $reader
    #|   i32.const 8 i64.load local.set $writer
    #|   local.get $bus local.get $reader i32.const 1 call $register i32.const 1 i32.ne if unreachable end
    #|   local.get $bus local.get $writer i32.const 0 call $register i32.const 1 i32.ne if unreachable end
    #|   i32.const 32 i32.const 0 i32.const 5 i64.const 0 call $makewrite local.set $write
    #|   i32.const 5 i64.const 0 call $makeread local.set $read
    #|   local.get $writer local.get $write call $write i32.const -1 i32.ne if unreachable end
    #|   local.get $reader local.get $read call $read i32.const -1 i32.ne if unreachable end
    #|   local.get $reader call $close if unreachable end
    #|   local.get $writer call $close if unreachable end
    #|   i32.const 32 i32.const 120 i32.store8
    #|   i32.const 1 memory.grow drop
    #|   (block $done (loop $again
    #|     local.get $completed i32.const 2 i32.eq br_if $done
    #|     local.get $bus i32.const 5000 call $wait local.tee $count i32.eqz if unreachable end
    #|     i32.const 0 local.set $index
    #|     (loop $events
    #|       local.get $bus local.get $index call $event call $token local.tee $token
    #|       local.get $read i64.eq
    #|       if
    #|         local.get $read local.get $reader call $status i32.const 5 i32.ne if unreachable end
    #|         local.get $read i32.const 65536 i32.const 0 i32.const 5 call $copy
    #|         i32.const 65536 i32.load8_u i32.const 104 i32.ne if unreachable end
    #|         local.get $read call $free
    #|       else
    #|         local.get $token local.get $write i64.ne if unreachable end
    #|         local.get $write local.get $writer call $status i32.const 5 i32.ne if unreachable end
    #|         local.get $write call $free
    #|       end
    #|       local.get $completed i32.const 1 i32.add local.set $completed
    #|       local.get $index i32.const 1 i32.add local.tee $index local.get $count i32.lt_s br_if $events)
    #|     br $again))))
  assert_eq(compile(source).run(), Completed)
}
