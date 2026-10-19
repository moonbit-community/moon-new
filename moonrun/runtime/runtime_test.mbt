///|
fn compile(source : String) -> @runtime.Module raise {
  let bytes = @encoder.encode(@wat.parse(source)).map(value => value.to_byte())
  @runtime.Module::from_bytes(Bytes::from_array(bytes))
}

///|
fn waiting_guest(timeout : Int32) -> @runtime.Module raise {
  compile(
    (
      #|(module
      #| (import "moonbitlang/async" "event_bus/create" (func $create (result i64)))
      #| (import "moonbitlang/async" "event_bus/destroy" (func $destroy (param i64)))
      #| (import "moonbitlang/async" "event_bus/wait" (func $wait (param i64 i32) (result i32)))
      #| (import "spectest" "print_char" (func $print (param i32)))
      #| (func (export "_start") (local $bus i64)
      #|   i32.const 42 call $print
      #|   call $create local.tee $bus
      #|   i32.const TIMEOUT call $wait
      #|   if unreachable end
      #|   local.get $bus call $destroy
      #|   i32.const 43 call $print))
    ).replace(old="TIMEOUT", new=timeout.to_string()),
  )
}

///|
async test "guest event wait participates in an already running async loop" {
  let program = waiting_guest(100)
  let ticked = Ref(false)
  let finished = Ref(false)
  let started = Ref(false)
  let ready = @cond_var.Cond()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      while !started.val {
        ready.wait()
      }
      @async.sleep(10)
      assert_false(finished.val)
      ticked.val = true
    })
    assert_eq(
      program.run(stdout=bytes => {
        if bytes == b"*" {
          started.val = true
          ready.signal()
        } else {
          finished.val = true
        }
      }),
      Completed,
    )
    assert_true(ticked.val)
  })
}

///|
async test "concurrent guests have independent event buses" {
  let first = waiting_guest(10)
  let second = waiting_guest(30)
  assert_eq(
    @async.all([
      () => first.run(stdout=_ => ()),
      () => second.run(stdout=_ => ()),
    ]),
    [Completed, Completed],
  )
}

///|
async test "an infinite guest event wait is cancellable and releases its worker" {
  let program = waiting_guest(-1)
  for _ in 0..<3 {
    assert_true(
      @async.with_timeout_opt(10, () => program.run(stdout=_ => ())) is None,
    )
  }
  assert_eq(waiting_guest(0).run(stdout=_ => ()), Completed)
}

///|
async test "a reused event bus remains cancellable after completed waits" {
  let program = compile(
    (
      #|(module
      #| (import "moonbitlang/async" "event_bus/create" (func $create (result i64)))
      #| (import "moonbitlang/async" "event_bus/wait" (func $wait (param i64 i32) (result i32)))
      #| (import "spectest" "print_char" (func $print (param i32)))
      #| (func (export "_start") (local $bus i64) (local $remaining i32)
      #|   call $create local.set $bus
      #|   i32.const 20 local.set $remaining
      #|   (loop $again
      #|     local.get $bus i32.const 0 call $wait
      #|     if unreachable end
      #|     local.get $remaining i32.const 1 i32.sub local.tee $remaining
      #|     br_if $again)
      #|   i32.const 42 call $print
      #|   local.get $bus i32.const -1 call $wait
      #|   unreachable))
    ),
  )
  let finished_waits = Ref(false)
  assert_true(
    @async.with_timeout_opt(500, () => {
      program.run(stdout=_ => finished_waits.val = true)
    })
    is None,
  )
  assert_true(finished_waits.val)
}

///|
async test "guest pipe handles are owned and closed without exposing native pointers" {
  let program = compile(
    (
      #|(module
      #| (import "moonbitlang/async" "fd_util/pipe" (func $pipe (param i32 i32 i32 i32) (result i32)))
      #| (import "moonbitlang/async" "fd_util/close_fd" (func $close (param i64) (result i32)))
      #| (memory (export "memory") 1)
      #| (func (export "_start")
      #|   i32.const 0 i32.const 2 i32.const 1 i32.const 1 call $pipe
      #|   if unreachable end
      #|   i32.const 0 i64.load call $close if unreachable end
      #|   i32.const 8 i64.load call $close if unreachable end))
    ),
  )
  assert_eq(program.run(), Completed)
  assert_eq(program.run(), Completed)
}

///|
async test "pipe ABI faults and closed handles return errno without terminating the guest" {
  let program = compile(
    (
      #|(module
      #| (import "moonbitlang/async" "event_bus/create" (func $create (result i64)))
      #| (import "moonbitlang/async" "event_bus/try_register" (func $register (param i64 i64 i32) (result i32)))
      #| (import "moonbitlang/async" "fd_util/pipe" (func $pipe (param i32 i32 i32 i32) (result i32)))
      #| (import "moonbitlang/async" "fd_util/close_fd" (func $close (param i64) (result i32)))
      #| (import "moonbitlang/async" "io/read/unix" (func $read (param i64 i32 i32 i32) (result i32)))
      #| (import "moonbitlang/async" "io/write/unix" (func $write (param i64 i32 i32 i32) (result i32)))
      #| (import "moonbitlang/async" "os_error/get_errno" (func $errno (result i32)))
      #| (memory (export "memory") 1)
      #| (func $check (param $result i32) (param $expected i32)
      #|   local.get $result i32.const -1 i32.ne if unreachable end
      #|   call $errno local.get $expected i32.ne if unreachable end)
      #| (func (export "_start") (local $read i64) (local $bus i64)
      #|   i32.const -8 i32.const 2 i32.const 1 i32.const 1 call $pipe
      #|   i32.const FAULT call $check
      #|   i32.const 0 i32.const 1 i32.const 1 i32.const 1 call $pipe
      #|   i32.const FAULT call $check
      #|   i32.const 0 i32.const 2 i32.const 1 i32.const 1 call $pipe
      #|   if unreachable end
      #|   i32.const 0 i64.load local.set $read
      #|   local.get $read i32.const 65536 i32.const 0 i32.const 1 call $read
      #|   i32.const FAULT call $check
      #|   i32.const 8 i64.load i32.const 65536 i32.const 0 i32.const 1 call $write
      #|   i32.const FAULT call $check
      #|   local.get $read i32.const -1 i32.const 2 i32.const 1 call $read
      #|   i32.const FAULT call $check
      #|   local.get $read call $close if unreachable end
      #|   local.get $read call $close i32.const BADF call $check
      #|   local.get $read i32.const 32 i32.const 0 i32.const 1 call $read
      #|   i32.const BADF call $check
      #|   call $create local.set $bus
      #|   local.get $bus local.get $read i32.const 1 call $register
      #|   i32.const BADF call $check
      #|   i64.const 0 i32.const 8 i64.load i32.const 1 call $register
      #|   i32.const BADF call $check))
    )
    .replace_all(
      old="FAULT",
      new=if @async.platform is Windows { "487" } else { "14" },
    )
    .replace_all(
      old="BADF",
      new=if @async.platform is Windows { "6" } else { "9" },
    ),
  )
  assert_eq(program.run(), Completed)
}

///|
async test "guest Unix pipe readiness survives memory growth and concurrent runs" {
  if @async.platform is Windows {
    return
  }
  let program = compile(
    (
      #|(module
      #| (import "moonbitlang/async" "event_bus/create" (func $create (result i64)))
      #| (import "moonbitlang/async" "event_bus/destroy" (func $destroy (param i64)))
      #| (import "moonbitlang/async" "event_bus/try_register" (func $register (param i64 i64 i32) (result i32)))
      #| (import "moonbitlang/async" "event_bus/wait" (func $wait (param i64 i32) (result i32)))
      #| (import "moonbitlang/async" "event_bus/get_event" (func $event (param i64 i32) (result i64)))
      #| (import "moonbitlang/async" "event_bus/event_fd" (func $fd (param i64) (result i64)))
      #| (import "moonbitlang/async" "event_bus/event_events/unix" (func $flags (param i64) (result i32)))
      #| (import "moonbitlang/async" "fd_util/pipe" (func $pipe (param i32 i32 i32 i32) (result i32)))
      #| (import "moonbitlang/async" "io/read/unix" (func $read (param i64 i32 i32 i32) (result i32)))
      #| (import "moonbitlang/async" "io/write/unix" (func $write (param i64 i32 i32 i32) (result i32)))
      #| (import "moonbitlang/async" "os_error/get_errno" (func $errno (result i32)))
      #| (memory (export "memory") 1)
      #| (data (i32.const 32) "A")
      #| (func (export "_start") (local $bus i64) (local $read i64) (local $event i64)
      #|   i32.const 0 i32.const 2 i32.const 1 i32.const 1 call $pipe
      #|   if unreachable end
      #|   i32.const 0 i64.load local.set $read
      #|   call $create local.set $bus
      #|   local.get $bus local.get $read i32.const 1 call $register
      #|   i32.const 1 i32.ne if unreachable end
      #|   local.get $read i32.const 64 i32.const 3 i32.const 1 call $read
      #|   i32.const -1 i32.ne if unreachable end
      #|   call $errno i32.eqz if unreachable end
      #|   local.get $bus i32.const 0 call $wait if unreachable end
      #|   i32.const 1 memory.grow drop
      #|   i32.const 8 i64.load i32.const 32 i32.const 0 i32.const 1 call $write
      #|   i32.const 1 i32.ne if unreachable end
      #|   local.get $bus i32.const 1000 call $wait
      #|   i32.const 1 i32.lt_s if unreachable end
      #|   local.get $bus i32.const 0 call $event local.tee $event
      #|   call $fd local.get $read i64.ne if unreachable end
      #|   local.get $event call $flags i32.const 1 i32.and
      #|   i32.eqz if unreachable end
      #|   local.get $read i32.const 64 i32.const 3 i32.const 1 call $read
      #|   i32.const 1 i32.ne if unreachable end
      #|   i32.const 67 i32.load8_u i32.const 65 i32.ne if unreachable end
      #|   local.get $bus call $destroy))
    ),
  )
  assert_eq(@async.all([() => program.run(), () => program.run()]), [
    Completed,
    Completed,
  ])
}

///|
async test "start sections, _start and UTF-16 output" {
  let program = compile(
    (
      #|(module
      #| (import "spectest" "print_char" (func $print (param i32)))
      #| (func $init i32.const 65 call $print)
      #| (start $init)
      #| (func (export "_start")
      #|   i32.const 55357 call $print
      #|   i32.const 56832 call $print
      #|   i32.const 10 call $print))
    ),
  )
  let output = []
  assert_eq(program.run(stdout=bytes => output.push(bytes)), Completed)
  assert_eq(
    output.fold(init=b"", (all, bytes) => all + bytes),
    b"A\xf0\x9f\x98\x80\n",
  )
}

///|
async test "guest exit does not exit or poison the embedding host" {
  let program = compile(
    (
      #|(module
      #| (import "__moonbit_sys_unstable" "exit" (func $exit (param i32)))
      #| (func (export "_start") i32.const 17 call $exit unreachable))
    ),
  )
  assert_eq(program.run(), Exited(17))
  assert_eq(program.run(), Exited(17))
  assert_eq(compile("(module)").run(), Completed)
}

///|
async test "guest trap is returned separately from host setup errors" {
  let program = compile("(module (func (export \"_start\") unreachable))")
  assert_true(program.run() is Trapped(_))
  let missing = compile("(module (import \"unknown\" \"function\" (func)))")
  let error = try {
    ignore(missing.run())
    ""
  } catch {
    error => "\{error}"
  }
  assert_true(error.contains("unknown"))
}

///|
async test "nonconforming host signatures fail before execution" {
  let program = compile(
    (
      #|(module
      #| (import "spectest" "print_char" (func (param i64))))
    ),
  )
  let error = try {
    ignore(program.run())
    ""
  } catch {
    error => "\{error}"
  }
  assert_true(error.contains("incompatible"))
}

///|
async test "CPU-bound guest yields and can be cancelled" {
  let program = compile("(module (func (export \"_start\") (loop br 0)))")
  assert_true(@async.with_timeout_opt(20, () => program.run()) is None)
  assert_eq(compile("(module)").run(), Completed)
}

///|
async test "filesystem imports suspend without repeating side effects" {
  let directory = @fs.tmpdir(prefix="moonrun-test-")
  defer @fs.rmdir(directory, recursive=true) |> ignore
  let program = compile(
    (
      #|(module
      #| (import "__moonbit_fs_unstable" "create_dir_new" (func $mkdir (param externref) (result i32)))
      #| (import "__moonbit_fs_unstable" "is_dir_new" (func $isdir (param externref) (result i32)))
      #| (import "_" "nested" (global $path externref))
      #| (func (export "_start")
      #|   global.get $path call $mkdir
      #|   if unreachable end
      #|   global.get $path call $isdir
      #|   i32.const 1 i32.ne if unreachable end))
    ),
  )
  assert_eq(program.run(cwd=directory), Completed)
  assert_true(@fs.kind(directory + "/nested") is Directory)
}

///|
async test "environment changes are isolated to each run" {
  let program = compile(
    (
      #|(module
      #| (import "__moonbit_fs_unstable" "get_env_var_exists" (func $exists (param externref) (result i32)))
      #| (import "__moonbit_fs_unstable" "set_env_var" (func $set (param externref externref)))
      #| (import "_" "MOONRUN_PRIVATE_TEST" (global $key externref))
      #| (import "_" "value" (global $value externref))
      #| (func (export "_start")
      #|   global.get $key call $exists if unreachable end
      #|   global.get $key global.get $value call $set
      #|   global.get $key call $exists i32.eqz if unreachable end))
    ),
  )
  let environment : Map[String, String] = Map([])
  assert_eq(program.run(env=environment), Completed)
  assert_eq(program.run(env=environment), Completed)
  assert_true(environment.is_empty())
}

///|
async test "guest exception imports preserve Wasm catch semantics" {
  let program = compile(
    (
      #|(module
      #| (import "exception" "tag" (tag $error))
      #| (import "exception" "throw" (func $throw))
      #| (func (export "_start")
      #|   (block $caught
      #|     (try_table (catch $error $caught) call $throw)
      #|     unreachable)))
    ),
  )
  assert_eq(program.run(), Completed)
}

///|
async test "stdin decodes split UTF-8 and preserves remaining binary input" {
  let program = compile(
    (
      #|(module
      #| (import "__moonbit_io_unstable" "read_char" (func $char (result i32)))
      #| (import "__moonbit_io_unstable" "read_bytes_from_stdin" (func $bytes (result externref)))
      #| (import "ffi-bytes" "length" (func $length (param externref) (result i32)))
      #| (func (export "_start")
      #|   call $char i32.const 128512 i32.ne if unreachable end
      #|   call $bytes call $length i32.const 3 i32.ne if unreachable end))
    ),
  )
  let chunks = [b"\xf0", b"\x9f", b"\x98", b"\x80\x00\xff\x42"]
  let index = Ref(0)
  assert_eq(
    program.run(stdin=() => {
      let chunk = chunks.get(index.val).unwrap_or(b"")
      index.val += 1
      chunk
    }),
    Completed,
  )
}

///|
async test "ffi-bytes copy preserves overlapping source and checks bounds" {
  let program = compile(
    (
      #|(module
      #| (import "ffi-bytes" "new" (func $new (param i32) (result externref)))
      #| (import "ffi-bytes" "set" (func $set (param externref i32 i32)))
      #| (import "ffi-bytes" "get" (func $get (param externref i32) (result i32)))
      #| (import "ffi-bytes" "copy" (func $copy (param externref i32 externref i32 i32)))
      #| (func (export "_start") (local $bytes externref)
      #|   i32.const 3 call $new local.set $bytes
      #|   local.get $bytes i32.const 0 i32.const 1 call $set
      #|   local.get $bytes i32.const 1 i32.const 2 call $set
      #|   local.get $bytes i32.const 1 local.get $bytes i32.const 0 i32.const 2 call $copy
      #|   local.get $bytes i32.const 2 call $get i32.const 2 i32.ne if unreachable end))
    ),
  )
  assert_eq(program.run(), Completed)
  let invalid = compile(
    (
      #|(module
      #| (import "ffi-bytes" "new" (func $new (param i32) (result externref)))
      #| (import "ffi-bytes" "get" (func $get (param externref i32) (result i32)))
      #| (func (export "_start") i32.const 1 call $new i32.const 1 call $get drop))
    ),
  )
  assert_true(invalid.run() is Trapped(_))
}

///|
async test "JS strings use UTF-16 code units and guest i16 arrays" {
  let program = compile(
    (
      #|(module
      #| (type $units (array (mut i16)))
      #| (import "wasm:js-string" "fromCharCodeArray" (func $from (param (ref $units) i32 i32) (result externref)))
      #| (import "wasm:js-string" "length" (func $length (param externref) (result i32)))
      #| (import "wasm:js-string" "codePointAt" (func $point (param externref i32) (result i32)))
      #| (func (export "_start") (local $text externref)
      #|   i32.const 55357 i32.const 56832 array.new_fixed $units 2
      #|   i32.const 0 i32.const 2 call $from local.set $text
      #|   local.get $text call $length i32.const 2 i32.ne if unreachable end
      #|   local.get $text i32.const 0 call $point i32.const 128512 i32.ne if unreachable end))
    ),
  )
  assert_eq(program.run(), Completed)
}

///|
async test "WASI output and proc_exit are isolated per run" {
  let program = compile(
    (
      #|(module
      #| (import "wasi_snapshot_preview1" "fd_write" (func $write (param i32 i32 i32 i32) (result i32)))
      #| (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
      #| (memory (export "memory") 1)
      #| (data (i32.const 16) "\00\ff\42")
      #| (func (export "_start")
      #|   i32.const 0 i32.const 16 i32.store
      #|   i32.const 4 i32.const 3 i32.store
      #|   i32.const 1 i32.const 0 i32.const 1 i32.const 8 call $write
      #|   if unreachable end
      #|   i32.const 23 call $exit))
    ),
  )
  for _ in 0..<2 {
    let output = []
    assert_eq(program.run(stdout=bytes => output.push(bytes)), Exited(23))
    assert_eq(output, [b"\x00\xff\x42"])
  }
}

///|
async test "invalid test selections fail before guest start side effects" {
  let program = compile(
    (
      #|(module
      #| (import "spectest" "print_char" (func $print (param i32)))
      #| (func $init i32.const 65 call $print)
      #| (start $init))
    ),
  )
  let output = []
  let failed = try {
    ignore(program.run(test_args="{}", stdout=bytes => output.push(bytes)))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_true(output.is_empty())
}

///|
async test "core and WASI reads share prefetched standard input" {
  let program = compile(
    (
      #|(module
      #| (import "__moonbit_io_unstable" "read_char" (func $char (result i32)))
      #| (import "wasi_snapshot_preview1" "fd_read" (func $read (param i32 i32 i32 i32) (result i32)))
      #| (memory (export "memory") 1)
      #| (func (export "_start")
      #|   call $char i32.const 65 i32.ne if unreachable end
      #|   i32.const 0 i32.const 16 i32.store
      #|   i32.const 4 i32.const 3 i32.store
      #|   i32.const 0 i32.const 0 i32.const 1 i32.const 8 call $read
      #|   if unreachable end
      #|   i32.const 8 i32.load i32.const 3 i32.ne if unreachable end
      #|   i32.const 16 i32.load8_u i32.const 66 i32.ne if unreachable end
      #|   i32.const 18 i32.load8_u i32.const 68 i32.ne if unreachable end))
    ),
  )
  let sent = Ref(false)
  assert_eq(
    program.run(stdin=() => {
      if sent.val {
        b""
      } else {
        sent.val = true
        b"ABCD"
      }
    }),
    Completed,
  )
}

///|
async test "empty core filenames do not resolve to the working directory" {
  let parent = @fs.tmpdir(prefix="moonrun-empty-path-")
  defer @fs.rmdir(parent, recursive=true) |> ignore
  let directory = parent + "/work"
  @fs.mkdir(directory)
  @fs.write_file(directory + "/keep", b"keep")
  let program = compile(
    (
      #|(module
      #| (import "__moonbit_fs_unstable" "remove_dir_new" (func $remove (param externref) (result i32)))
      #| (import "_" "" (global $empty externref))
      #| (func (export "_start")
      #|   global.get $empty call $remove i32.const -1 i32.ne if unreachable end))
    ),
  )
  assert_eq(program.run(cwd=directory), Completed)
  assert_eq(@fs.read_file(directory + "/keep").binary(), b"keep")
}

///|
async test "core filenames retain symlink and parent-directory semantics" {
  if @async.platform is Windows {
    return
  }
  let directory = @fs.tmpdir(prefix="moonrun-symlink-path-")
  defer @fs.rmdir(directory, recursive=true) |> ignore
  @fs.mkdir(directory + "/target/child", recursive=true)
  @fs.symlink(target=directory + "/target/child", directory + "/link")
  @fs.write_file(directory + "/value", b"A")
  @fs.write_file(directory + "/target/value", b"B")
  let program = compile(
    (
      #|(module
      #| (import "__moonbit_fs_unstable" "read_file_to_string" (func $read (param externref) (result externref)))
      #| (import "wasm:js-string" "charCodeAt" (func $char (param externref i32) (result i32)))
      #| (import "_" "link/../value" (global $path externref))
      #| (func (export "_start")
      #|   global.get $path call $read i32.const 0 call $char
      #|   i32.const 66 i32.ne if unreachable end))
    ),
  )
  assert_eq(program.run(cwd=directory), Completed)
}

///|
async test "core environment mutations are visible through WASI" {
  let program = compile(
    (
      #|(module
      #| (import "__moonbit_fs_unstable" "set_env_var" (func $set (param externref externref)))
      #| (import "__moonbit_fs_unstable" "unset_env_var" (func $unset (param externref)))
      #| (import "wasi_snapshot_preview1" "environ_sizes_get" (func $sizes (param i32 i32) (result i32)))
      #| (import "wasi_snapshot_preview1" "environ_get" (func $get (param i32 i32) (result i32)))
      #| (import "_" "K" (global $key externref))
      #| (import "_" "V" (global $value externref))
      #| (import "_" "OLD" (global $old externref))
      #| (memory (export "memory") 1)
      #| (func (export "_start")
      #|   global.get $key global.get $value call $set
      #|   global.get $old call $unset
      #|   i32.const 0 i32.const 4 call $sizes if unreachable end
      #|   i32.const 0 i32.load i32.const 1 i32.ne if unreachable end
      #|   i32.const 4 i32.load i32.const 4 i32.ne if unreachable end
      #|   i32.const 8 i32.const 16 call $get if unreachable end
      #|   i32.const 16 i32.load i32.const 0x00563d4b i32.ne if unreachable end))
    ),
  )
  assert_eq(program.run(env={ "OLD": "old" }), Completed)
}

///|
async test "absolute core filenames override the run working directory" {
  let directory = @fs.tmpdir(prefix="moonrun-absolute-path-")
  defer @fs.rmdir(directory, recursive=true) |> ignore
  @fs.mkdir(directory + "/work")
  let path = directory + "/value"
  @fs.write_file(path, b"B")
  let program = compile(
    (
      #|(module
      #| (import "__moonbit_fs_unstable" "args_get" (func $args (result externref)))
      #| (import "__moonbit_fs_unstable" "array_get" (func $get (param externref i32) (result externref)))
      #| (import "__moonbit_fs_unstable" "read_file_to_string" (func $read (param externref) (result externref)))
      #| (import "wasm:js-string" "charCodeAt" (func $char (param externref i32) (result i32)))
      #| (func (export "_start")
      #|   call $args i32.const 1 call $get call $read
      #|   i32.const 0 call $char i32.const 66 i32.ne if unreachable end))
    ),
  )
  assert_eq(program.run(args=[path], cwd=directory + "/work"), Completed)
  if @async.platform is Windows && path is ['a'..<='z' | 'A'..<='Z', ':', ..] {
    assert_eq(
      program.run(args=[path[2:].to_owned()], cwd=directory + "/work"),
      Completed,
    )
  }
}

///|
async test "Unix pipe endpoint modes preserve nonblocking and blocking operations" {
  if @async.platform is Windows {
    return
  }
  let source =
    #|(module
    #| (import "moonbitlang/async" "fd_util/pipe" (func $pipe (param i32 i32 i32 i32) (result i32)))
    #| (import "moonbitlang/async" "io/read/unix" (func $read (param i64 i32 i32 i32) (result i32)))
    #| (import "moonbitlang/async" "io/write/unix" (func $write (param i64 i32 i32 i32) (result i32)))
    #| (memory (export "memory") 1)
    #| (data (i32.const 32) "x")
    #| (func (export "_start")
    #|   i32.const 0 i32.const 2 i32.const READ_ASYNC i32.const WRITE_ASYNC call $pipe if unreachable end
    #|   EMPTY_READ
    #|   i32.const 8 i64.load i32.const 32 i32.const 0 i32.const 1 call $write i32.const 1 i32.ne if unreachable end
    #|   i32.const 0 i64.load i32.const 48 i32.const 0 i32.const 1 call $read i32.const 1 i32.ne if unreachable end
    #|   i32.const 48 i32.load8_u i32.const 120 i32.ne if unreachable end))
  for read_async in [0, 1] {
    for write_async in [0, 1] {
      let program = compile(
        source
        .replace(old="READ_ASYNC", new=read_async.to_string())
        .replace(old="WRITE_ASYNC", new=write_async.to_string())
        .replace(
          old="EMPTY_READ",
          new=if read_async == 1 {
            "i32.const 0 i64.load i32.const 48 i32.const 0 i32.const 1 call $read i32.const -1 i32.ne if unreachable end"
          } else {
            ""
          },
        ),
      )
      assert_eq(program.run(), Completed)
    }
  }
}
