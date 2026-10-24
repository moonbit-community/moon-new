///|
test "default execution uses JIT beyond the interpreter call limit" {
  let program = compile(
    (
      #|(module
      #| (func $count (param $n i32) (result i32)
      #|   local.get $n i32.eqz
      #|   if (result i32)
      #|     i32.const 0
      #|   else
      #|     local.get $n i32.const 1 i32.sub call $count
      #|     i32.const 1 i32.add
      #|   end)
      #| (func (export "_start")
      #|   i32.const 2000 call $count
      #|   i32.const 2000 i32.ne if unreachable end))
    ),
  )
  assert_eq(program.run(), Completed)
}

///|
test "guest trap frames can be omitted without losing the cause" {
  let program = compile(
    (
      #|(module
      #| (memory 1)
      #| (func $leaf (param i32) (result i32)
      #|   local.get 0 i32.load)
      #| (func $middle (param i32) (result i32)
      #|   local.get 0 call $leaf i32.const 1 i32.add)
      #| (func $outer (param i32) (result i32)
      #|   local.get 0 call $middle i32.const 1 i32.add)
      #| (func (export "_start")
      #|   i32.const 65536 call $outer drop))
    ),
  )
  guard program.run() is Trapped(message) else { fail("missing trap") }
  let frames = message
    .split("\n")
    .drop(1)
    .map(line => line.split(" (").next().unwrap().to_owned())
    .collect()
  assert_eq(frames, [
    "    at leaf", "    at middle", "    at outer", "    at _start",
  ])
  assert_true(message.contains("out of bounds memory access"), msg=message)
  guard program.run(no_stack_trace=true) is Trapped(without_frames) else {
    fail("missing trap without frames")
  }
  assert_eq(without_frames, "out of bounds memory access")
}

///|
test "stack size is a validated KiB budget" {
  let program = compile(
    (
      #|(module
      #| (func $count (param $n i32) (result i32)
      #|   local.get $n i32.eqz
      #|   if (result i32) i32.const 0
      #|   else
      #|     local.get $n i32.const 1 i32.sub call $count
      #|     i32.const 1 i32.add
      #|   end)
      #| (func (export "_start")
      #|   i32.const 10000 call $count
      #|   i32.const 10000 i32.ne if unreachable end))
    ),
  )
  guard program.run(stack_size=64L) is Trapped(message) else {
    fail("small guest stack should trap")
  }
  assert_true(message.contains("call stack exhausted"), msg=message)
  assert_eq(program.run(stack_size=4096L), Completed)
  for size in [0L, -1L, 9223372036854775807L] {
    let rejected = try {
      ignore(program.run(stack_size=size))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "test-driver trap results respect no_stack_trace" {
  let program = compile(
    (
      #|(module
      #| (func (export "moonbit_test_driver_internal_execute") (param externref i32)
      #|   unreachable)
      #| (func (export "moonbit_test_driver_finish")))
    ),
  )
  for no_stack_trace in [false, true] {
    let output = StringBuilder()
    assert_eq(
      program.run(
        no_stack_trace~,
        test_args=(
          #|{"package":"probe","file_and_index":[["probe.mbt",[{"start":0,"end":1}]]]}
        ),
        stdout=bytes => output.write_string(@utf8.decode_lossy(bytes)),
      ),
      Completed,
    )
    let output = output.to_string()
    assert_true(output.contains("unreachable"), msg=output)
    assert_true(
      output.contains("at moonbit_test_driver_internal_execute") ==
      !no_stack_trace,
      msg=output,
    )
  }
}

///|
test "trap source maps use original binary positions for leaves and callers" {
  let directory = @sys.tmpdir(prefix="moonrun-mapped-trap-")
  defer @sys.rmdir(directory, recursive=true) |> ignore
  let path = directory + "/trap.wasm"
  // Padding and a noncanonical locals LEB make re-encoding move the offsets.
  // The leaf traps at byte 49; the non-tail caller's call is at byte 53.
  let bytes = b"\x00asm\x01\x00\x00\x00\x00\x06\x01x\x00\x00\x00\x00\x01\x08\x02\x60\x00\x00\x60\x00\x01\x7f\x03\x03\x02\x00\x01\x07\x0a\x01\x06_start\x00\x01\x0a\x0d\x02\x04\x80\x00\x00\x0b\x06\x00\x10\x00\x41\x07\x0b"
  assert_eq(bytes[49], b'\x00')
  assert_eq(bytes[53], b'\x10')
  @sys.write_file(path, bytes)
  @sys.write_file(
    path + ".map",
    b"{\"sources\":[\"incorrect.mbt\",\"leaf.mbt\",\"caller.mbt\"],\"mappings\":\"AAAA,iDCOA,ICIA,CFXA\"}",
  )
  let program = @runtime.Module::load_file(path)
  @sys.remove(path + ".map")
  guard program.run() is Trapped(message) else { fail("missing trap") }
  assert_true(message.contains("JIT +0x"), msg=message)
  assert_true(message.contains("at func_0 leaf.mbt:8"), msg=message)
  assert_true(message.contains("at _start caller.mbt:12"), msg=message)
  assert_true(!message.contains("incorrect.mbt"), msg=message)
  guard program.run(no_stack_trace=true) is Trapped(without_frames) else {
    fail("missing trap without frames")
  }
  assert_eq(without_frames, "unreachable")
}
