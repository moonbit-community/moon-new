// Compatibility regressions; original probes from moon/crates/moonrun/tests at 12e9d22e.

///|
test "byte builders copy on finish and readers observe mutation" {
  let source =
    #|(module
    #|        (import "__moonbit_fs_unstable" "begin_create_byte_array" (func $builder (result externref)))
    #|        (import "__moonbit_fs_unstable" "byte_array_append_byte" (func $append (param externref i32)))
    #|        (import "__moonbit_fs_unstable" "finish_create_byte_array" (func $finish (param externref) (result externref)))
    #|        (import "__moonbit_fs_unstable" "begin_read_byte_array" (func $reader (param externref) (result externref)))
    #|        (import "__moonbit_fs_unstable" "byte_array_read_byte" (func $read (param externref) (result i32)))
    #|        (import "__moonbit_fs_unstable" "finish_read_byte_array" (func $close (param externref)))
    #|        (import "ffi-bytes" "set" (func $set (param externref i32 i32) (result i32)))
    #|        (import "ffi-bytes" "length" (func $length (param externref) (result i32)))
    #|        (func $eq (param i32 i32) local.get 0 local.get 1 i32.ne if unreachable end)
    #|        (func (export "_start") (local $b externref) (local $a externref) (local $r externref)
    #|            call $builder local.set $b
    #|            local.get $b call $finish call $length i32.const 0 call $eq
    #|            local.get $b i32.const -1 call $append
    #|            local.get $b i32.const 256 call $append
    #|            local.get $b i32.const 300 call $append
    #|            local.get $b call $finish local.set $a
    #|            local.get $b i32.const 99 call $append
    #|            local.get $a call $length i32.const 3 call $eq
    #|            local.get $a call $reader local.set $r
    #|            local.get $r call $read i32.const 255 call $eq
    #|            local.get $a i32.const 1 i32.const 258 call $set i32.const 258 call $eq
    #|            local.get $r call $read i32.const 2 call $eq
    #|            local.get $r call $read i32.const 44 call $eq
    #|            local.get $r call $read i32.const -1 call $eq
    #|            local.get $r call $close
    #|            local.get $r call $read i32.const -1 call $eq))
  assert_eq(compile(source).run(stdout=_ => ()), Completed)
}

///|
test "byte operations preserve overlap clamping and utf16" {
  let source =
    #|(module
    #|        (import "ffi-bytes" "memory" (memory 1))
    #|        (import "ffi-bytes" "from_memory" (func $from (param i32 i32) (result externref)))
    #|        (import "ffi-bytes" "copy" (func $copy (param externref i32 externref i32 i32)))
    #|        (import "ffi-bytes" "fill" (func $fill (param externref i32 i32 i32) (result externref)))
    #|        (import "ffi-bytes" "get" (func $get (param externref i32) (result i32)))
    #|        (import "ffi-bytes" "set" (func $set (param externref i32 i32)))
    #|        (import "ffi-bytes" "length" (func $len (param externref) (result i32)))
    #|        (import "ffi-bytes" "equals" (func $equals (param externref externref) (result i32)))
    #|        (import "ffi-bytes" "asString" (func $string (param externref i32 i32) (result externref)))
    #|        (import "__moonbit_fs_unstable" "begin_read_string" (func $reader (param externref) (result externref)))
    #|        (import "__moonbit_fs_unstable" "string_read_char" (func $read (param externref) (result i32)))
    #|        (data (i32.const 0) "\01\02\03\04\05\06")
    #|        (data (i32.const 16) "\00\d8\41\00\ff\dc\99")
    #|        (func $eq (param i32 i32) local.get 0 local.get 1 i32.ne if unreachable end)
    #|        (func (export "_start") (local $a externref) (local $b externref) (local $r externref)
    #|            i32.const 0 i32.const 6 call $from local.set $a
    #|            local.get $a i32.const 1 local.get $a i32.const 0 i32.const 5 call $copy
    #|            local.get $a i32.const 5 call $get i32.const 5 call $eq
    #|            local.get $a i32.const 2 call $get i32.const 2 call $eq
    #|            local.get $a i32.const 0 local.get $a i32.const 1 i32.const 5 call $copy
    #|            local.get $a i32.const 0 call $get i32.const 1 call $eq
    #|            local.get $a i32.const 4 call $get i32.const 5 call $eq
    #|            local.get $a i32.const 0 local.get $a i32.const -2 i32.const 100 call $copy
    #|            local.get $a i32.const 0 call $get i32.const 5 call $eq
    #|            local.get $a i32.const -2 i32.const 300 i32.const 100 call $fill local.set $b
    #|            local.get $a i32.const 4 call $get i32.const 44 call $eq
    #|            local.get $b i32.const 5 call $get i32.const 44 call $eq
    #|            local.get $a local.get $b call $equals i32.const 1 call $eq
    #|            local.get $a i32.const -1 call $get i32.const 0 call $eq
    #|            local.get $a i32.const 6 call $get i32.const 0 call $eq
    #|            local.get $a i32.const 6 i32.const 123 call $set
    #|            local.get $a call $len i32.const 6 call $eq
    #|            i32.const 16 i32.const 7 call $from i32.const 0 i32.const 7 call $string
    #|            call $reader local.set $r
    #|            local.get $r call $read i32.const 0xd800 call $eq
    #|            local.get $r call $read i32.const 65 call $eq
    #|            local.get $r call $read i32.const 0xdcff call $eq
    #|            local.get $r call $read i32.const -1 call $eq))
  assert_eq(compile(source).run(stdout=_ => ()), Completed)
}

///|
test "fractional slice indices truncate before relative clamping" {
  let source =
    #|(module
    #|        (import "ffi-bytes" "memory" (memory 1))
    #|        (import "ffi-bytes" "from_memory" (func $from (param f64 f64) (result externref)))
    #|        (import "ffi-bytes" "length" (func $len (param externref) (result i32)))
    #|        (import "ffi-bytes" "fill" (func $fill (param externref f64 i32 f64)))
    #|        (import "ffi-bytes" "get" (func $get (param externref i32) (result i32)))
    #|        (func $eq (param i32 i32) local.get 0 local.get 1 i32.ne if unreachable end)
    #|        (func (export "_start") (local $a externref)
    #|            f64.const -0.5 f64.const 3.5 call $from local.set $a
    #|            local.get $a call $len i32.const 3 call $eq
    #|            local.get $a f64.const -0.5 i32.const 65 f64.const 2.5 call $fill
    #|            local.get $a i32.const 0 call $get i32.const 65 call $eq
    #|            local.get $a i32.const 1 call $get i32.const 65 call $eq
    #|            local.get $a i32.const 2 call $get i32.const 0 call $eq))
  assert_eq(compile(source).run(stdout=_ => ()), Completed)
}

///|
test "byte memory is reacquired after growth and copies are independent" {
  let source =
    #|(module
    #|        (import "ffi-bytes" "memory" (memory 1))
    #|        (import "ffi-bytes" "from_memory" (func $from (param i32 i32) (result externref)))
    #|        (import "ffi-bytes" "get" (func $get (param externref i32) (result i32)))
    #|        (import "ffi-bytes" "length" (func $len (param externref) (result i32)))
    #|        (func $eq (param i32 i32) local.get 0 local.get 1 i32.ne if unreachable end)
    #|        (func (export "_start") (local $a externref)
    #|            i32.const 0 i32.const 65 i32.store8
    #|            i32.const 0 i32.const 1 call $from local.set $a
    #|            i32.const 0 i32.const 66 i32.store8
    #|            local.get $a i32.const 0 call $get i32.const 65 call $eq
    #|            i32.const 1 memory.grow i32.const 1 call $eq
    #|            i32.const 65536 i32.const 90 i32.store8
    #|            i32.const 65536 i32.const 1 call $from i32.const 0 call $get i32.const 90 call $eq
    #|            i32.const 131071 i32.const 10 call $from call $len i32.const 1 call $eq
    #|            i32.const -1 i32.const 2 call $from call $len i32.const 0 call $eq))
  assert_eq(compile(source).run(stdout=_ => ()), Completed)
}
