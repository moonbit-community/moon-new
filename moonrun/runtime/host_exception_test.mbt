// Compatibility probes from Rust moonrun's invalid_handles_and_byte_ranges test.

///|
test "ABI handle and range errors are catchable guest exceptions" {
  let imports =
    #| (import "ffi-bytes" "new" (func $new (param i32) (result externref)))
    #| (import "ffi-bytes" "get" (func $get (param externref i32) (result i32)))
    #| (import "ffi-bytes" "copy" (func $copy (param externref i32 externref i32 i32)))
    #| (import "__moonbit_fs_unstable" "begin_create_string" (func $builder (result externref)))
    #| (import "__moonbit_fs_unstable" "string_read_char" (func $read (param externref) (result i32)))
    #| (import "__moonbit_fs_unstable" "finish_create_byte_array" (func $finish (param externref) (result externref)))
  for
    operation in [
      "i32.const -1 call $new drop", "ref.null extern i32.const 0 call $get drop",
      "call $builder call $read drop", "call $builder call $finish drop", "local.get $a i32.const -1 local.get $a i32.const 0 i32.const 0 call $copy",
      "local.get $a i32.const 2 local.get $a i32.const 0 i32.const 1 call $copy",
    ] {
    let source =
      $|(module \{imports}
      $| (func (export "_start") (local $a externref)
      $|   i32.const 2 call $new local.set $a
      $|   (block $caught
      $|     (try_table (catch_all $caught) \{operation})
      $|     unreachable)))
    assert_eq(compile(source).run(), Completed, msg=operation)
  }
}

///|
test "uncaught host errors keep their diagnostic without becoming stale" {
  let imports = "(import \"ffi-bytes\" \"new\" (func $new (param i32) (result externref)))"
  let uncaught = compile(
    "(module \{imports} (func (export \"_start\") i32.const -1 call $new drop))",
  )
  assert_eq(uncaught.run(), Trapped("out of bounds array access"))
  let replaced = compile(
    (
      $|(module \{imports} (tag $other)
      $| (func (export "_start")
      $|   (block $caught
      $|     (try_table (catch_all $caught) i32.const -1 call $new drop)
      $|     unreachable)
      $|   throw $other))
    ),
  )
  assert_eq(replaced.run(), Trapped("uncaught exception"))
}

///|
test "guest traps remain uncatchable after enabling host exceptions" {
  let program = compile(
    (
      #|(module (func (export "_start")
      #| (block $caught (try_table (catch_all $caught) unreachable))))
    ),
  )
  assert_eq(program.run(no_stack_trace=true), Trapped("unreachable"))
}

///|
test "uncaught host exceptions retain their diagnostic after cooperative resumes" {
  let program = compile(
    (
      #|(module
      #| (import "ffi-bytes" "new" (func $new (param i32) (result externref)))
      #| (func (export "_start") (local $n i32)
      #|   i32.const 10000000 local.set $n
      #|   (loop $again
      #|     local.get $n i32.const 1 i32.sub local.tee $n br_if $again)
      #|   i32.const -1 call $new drop))
    ),
  )
  let polls = Ref(0)
  let control = @runtime.RunControl(poll=() => {
    polls.val += 1
    None
  })
  assert_eq(program.run(control~), Trapped("out of bounds array access"))
  // There is one host call; extra polls require cooperative guest progress.
  assert_true(polls.val > 1)
}
