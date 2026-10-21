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
  assert_true(message.contains("\n    at func_0"), msg=message)
  assert_true(message.contains("out of bounds memory access"), msg=message)
  // Deeper non-tail callers are currently lost upstream (#563).
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
