// Compatibility regressions; original probes from moon/crates/moonrun/tests at 12e9d22e.

///|
test "sanitizer checks lifetime duplicate allocations and final leaks" {
  let source =
    #|(module
    #| (import "moonbit:ffi/memory-sanitizer" "register-object-alloc" (func $alloc (param i32 i32)))
    #| (import "moonbit:ffi/memory-sanitizer" "register-object-free" (func $free (param i32)))
    #| (import "moonbit:ffi/memory-sanitizer" "object-is-valid" (func $valid (param i32) (result i32)))
    #| (func (export "_start")
    #|   i32.const 1024 call $valid if unreachable end
    #|   i32.const 16 i32.const 1024 call $alloc
    #|   i32.const 1024 call $valid i32.eqz if unreachable end
    #|   FINAL))
  assert_eq(
    compile(
      source.replace(
        old="FINAL",
        new="i32.const 1024 call $free i32.const 1024 call $valid if unreachable end",
      ),
    ).run(),
    Completed,
  )
  for
    (tail, message) in [
      (
        "i32.const 32 i32.const 1024 call $alloc", "object 1024 is already live with size 16",
      ),
      (
        "i32.const 1024 call $free i32.const 1024 call $free", "invalid object 1024",
      ),
      ("", "moonrun memory sanitizer detected 1 leaked object (16 bytes)"),
    ] {
    guard compile(source.replace(old="FINAL", new=tail)).run()
      is Trapped(actual) else {
      fail("sanitizer accepted invalid lifetime")
    }
    assert_true(actual.contains(message))
  }
  // The live map is isolated per execution, even when the compiled module is reused.
  let program = compile(
    source.replace(old="FINAL", new="i32.const 1024 call $free"),
  )
  assert_eq(program.run(), Completed)
  assert_eq(program.run(), Completed)
}

///|
test "host leak diagnostics are opt-in and run before cleanup" {
  let source =
    #|(module
    #| (import "moonbitlang/async" "event_bus/create" (func $new (result i64)))
    #| (import "moonbitlang/async" "event_bus/destroy" (func $free (param i64)))
    #| (func (export "_start") call $new drop))
  let program = compile(source)
  assert_eq(program.run(env={}), Completed)
  let errors = StringBuilder()
  assert_eq(
    program.run(env={ "MOONBIT_ASYNC_CHECK_FD_LEAK": "1" }, stderr=bytes => {
      errors.write_string(@utf8.decode_lossy(bytes))
    }),
    Exited(101),
  )
  assert_true(errors.to_string().contains("polls=1"))
  assert_eq(
    compile(source.replace(old="call $new drop", new="call $new call $free")).run(env={
        "MOONBIT_ASYNC_CHECK_FD_LEAK": "1",
      },
    ),
    Completed,
  )
}

///|
test "realpath result is borrowed from its job and published once" {
  let source =
    #|(module
    #| (import "moonbitlang/async" "thread_pool/make_realpath_job" (func $new (param i32 i32) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/run_job" (func $run (param i64)))
    #| (import "moonbitlang/async" "thread_pool/get_realpath_result" (func $result (param i64) (result i64)))
    #| (import "moonbitlang/async" "thread_pool/free_job" (func $free (param i64)))
    #| (import "moonbitlang/async" "c_buffer/length" (func $len (param i64) (result i32)))
    #| (memory (export "memory") 1)
    #| (data (i32.const 0) ".\00")
    #| (func (export "_start") (local $job i64) (local $buffer i64)
    #|   i32.const 0 i32.const 1 call $new local.tee $job call $run
    #|   local.get $job call $result local.set $buffer
    #|   local.get $job call $result local.get $buffer i64.ne if unreachable end
    #|   local.get $buffer call $len i32.eqz if unreachable end
    #|   local.get $job call $free
    #|   AFTER))
  assert_eq(
    compile(source.replace(old="AFTER", new="")).run(env={
      "MOONBIT_ASYNC_CHECK_FD_LEAK": "1",
    }),
    Completed,
  )
  assert_true(
    compile(source.replace(old="AFTER", new="local.get $buffer call $len drop")).run()
    is Trapped(_),
  )
}

///|
test "nullable handles use the reserved runtime null" {
  let source =
    #|(module
    #|                    (import "moonbitlang/sqlite" "sqlite3_null_handle" (func $null (result i64)))
    #|                    (import "moonbitlang/async" "c_buffer/is_null" (func $buffer_null (param i64) (result i32)))
    #|                    (import "moonbitlang/async" "c_buffer/free" (func $free_buffer (param i64)))
    #|                    (import "moonbitlang/async" "socket/if_indextoname" (func $ifname (param i32) (result i64)))
    #|                    (import "moonbitlang/async" "socket/addrinfo_is_null" (func $addrinfo_null (param i64) (result i32)))
    #|                    (import "moonbitlang/async" "socket/addrinfo_get_next" (func $next (param i64) (result i64)))
    #|                    (import "moonbitlang/async" "socket/addrinfo_addr_size" (func $size (param i64) (result i32)))
    #|                    (import "moonbitlang/async" "socket/addrinfo_free" (func $free_addrinfo (param i64)))
    #|                    (import "moonbitlang/async" "tls/connection/free" (func $free_tls (param i64)))
    #|                    (memory (export "memory") 1)
    #|                    (func (export "_start")
    #|                        (if (i32.eqz (call $buffer_null (call $null))) (then unreachable))
    #|                        (if (i32.eqz (call $addrinfo_null (call $null))) (then unreachable))
    #|                        (if (call $buffer_null (i64.const 0)) (then unreachable))
    #|                        (if (call $addrinfo_null (i64.const 0)) (then unreachable))
    #|                        (if (i64.ne (call $ifname (i32.const 0)) (call $null)) (then unreachable))
    #|                        (if (i64.ne (call $next (call $null)) (call $null)) (then unreachable))
    #|                        (if (call $size (call $null)) (then unreachable))
    #|                        (call $free_buffer (call $null))
    #|                        (call $free_addrinfo (call $null))
    #|                        (call $free_tls (call $null))))
  assert_eq(compile(source).run(), Completed)
}

///|
test "TLS free rejects a numeric zero handle" {
  let source =
    #|(module
    #|                    (import "moonbitlang/async" "tls/connection/free" (func $free (param i64)))
    #|                    (memory (export "memory") 1)
    #|                    (func (export "_start") (call $free (i64.const 0))))
  guard compile(source).run() is Trapped(message) else {
    fail("TLS free accepted zero")
  }
  assert_true(message.contains("Badf"))
}
