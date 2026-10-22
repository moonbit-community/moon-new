///|
let tls_setup_guest : String =
  #|(module
  #| (import "moonbitlang/async" "tls/connection/new" (func $new (result i64)))
  #| (import "moonbitlang/async" "tls/connection/free" (func $free (param i64)))
  #| (import "moonbitlang/async" "tls/connection/set_client" (func $client (param i64 i32 i32 i32 i32) (result i32)))
  #| (import "moonbitlang/async" "tls/connection/set_server_files" (func $files (param i64 i32 i32 i32 i32 i32 i32) (result i32)))
  #| (import "moonbitlang/async" "tls/connection/take_error" (func $error (param i64) (result i64)))
  #| (import "moonbitlang/async" "c_buffer/free" (func $buffer_free (param i64)))
  #| (import "moonbitlang/async" "os_string/decode_len" (func $length (param i64 i32 i32) (result i32)))
  #| (memory (export "memory") 1)
  #| (data (i32.const 0) "k\00e\00y\00")
  #| (data (i32.const 16) "c\00e\00r\00t\00")
  #| (func (export "_start") (local $tls i64) (local $error i64)
  #|   call $new local.set $tls
  #|   local.get $tls i32.const 0 i32.const 3 i32.const 1 i32.const 16 i32.const 4 i32.const 1 call $files
  #|   i32.const -1 i32.ne if unreachable end
  #|   local.get $tls call $error local.tee $error i32.const 0 i32.const -1 call $length
  #|   i32.const 0 i32.le_s if unreachable end
  #|   local.get $error call $buffer_free
  #|   local.get $tls i32.const 0 i32.const 0 i32.const 0 i32.const 0 call $client
  #|   if unreachable end
  #|   local.get $tls call $free))

///|
test "TLS certificate file policy failures are owned by the reusable handle" {
  let policy = @runtime.Policy::from_json("{}")
  let output = StringBuilder()
  assert_eq(
    compile(tls_setup_guest).run(policy~, stdout=_ => (), stderr=bytes => {
      output.write_string(@utf8.decode_lossy(bytes))
    }),
    Completed,
  )
  assert_true(output.to_string().contains("file read"))
}

///|
test "TLS certificate paths use the guest working directory" {
  if @sys.platform is Windows {
    return
  }
  let directory = @sys.tmpdir(prefix="moonrun-tls-cwd-")
  defer @sys.rmdir(directory, recursive=true)
  for (source, target) in [("key.pem", "key"), ("cert.pem", "cert")] {
    @sys.write_file(
      directory + "/" + target,
      @sys.read_file("async_host/tls/test_keys/" + source),
    )
  }
  let source =
    #|(module
    #| (import "moonbitlang/async" "tls/connection/new" (func $new (result i64)))
    #| (import "moonbitlang/async" "tls/connection/free" (func $free (param i64)))
    #| (import "moonbitlang/async" "tls/connection/set_server_files" (func $files (param i64 i32 i32 i32 i32 i32 i32) (result i32)))
    #| (memory (export "memory") 1)
    #| (data (i32.const 0) "k\00e\00y\00")
    #| (data (i32.const 16) "c\00e\00r\00t\00")
    #| (func (export "_start") (local $tls i64)
    #|   call $new local.set $tls
    #|   local.get $tls i32.const 0 i32.const 3 i32.const 1 i32.const 16 i32.const 4 i32.const 1 call $files
    #|   if unreachable end local.get $tls call $free))
  assert_eq(compile(source).run(cwd=directory), Completed)
}

///|
test "TLS guest buffers reject overlaps and out-of-bounds ranges" {
  let source =
    #|(module
    #| (import "moonbitlang/async" "tls/connection/new" (func $new (result i64)))
    #| (import "moonbitlang/async" "tls/connection/connect" (func $connect (param i64 i32 i32 i32 i32 i32 i32) (result i32)))
    #| (memory (export "memory") 1)
    #| (func (export "_start") call $new RANGES call $connect drop))
  for
    ranges in [
      "i32.const 0 i32.const 0 i32.const 4 i32.const 2 i32.const 0 i32.const 4",
      "i32.const 65535 i32.const 0 i32.const 2 i32.const 0 i32.const 0 i32.const 0",
      "i32.const -1 i32.const 1 i32.const 1 i32.const 0 i32.const 0 i32.const 0",
    ] {
    assert_true(
      compile(source.replace(old="RANGES", new=ranges)).run() is Trapped(_),
    )
  }
}

///|
test "TLS handles reject other resource kinds and freed identifiers" {
  let source =
    #|(module
    #| (import "moonbitlang/async" "tls/connection/new" (func $new (result i64)))
    #| (import "moonbitlang/async" "tls/connection/free" (func $free (param i64)))
    #| (import "moonbitlang/async" "tls/connection/bytes_read" (func $read (param i64) (result i32)))
    #| (import "moonbitlang/async" "c_buffer/new" (func $buffer (param i32) (result i64)))
    #| (func (export "_start") (local $old i64) BODY))
  for
    body in [
      "i32.const 0 call $buffer call $read drop", "call $new local.tee $old call $free call $new drop local.get $old call $read drop",
    ] {
    guard compile(source.replace(old="BODY", new=body)).run()
      is Trapped(message) else {
      fail("invalid TLS handle accepted")
    }
    assert_true(message.contains("Badf"))
  }
}

///|
test "TLS connections participate in leak diagnostics and per-run cleanup" {
  let source =
    #|(module
    #| (import "moonbitlang/async" "tls/connection/new" (func $new (result i64)))
    #| (func (export "_start") call $new drop))
  let program = compile(source)
  for _ in 0..<3 {
    let output = StringBuilder()
    assert_eq(
      program.run(env={ "MOONBIT_ASYNC_CHECK_FD_LEAK": "1" }, stderr=bytes => {
        output.write_string(@utf8.decode_lossy(bytes))
      }),
      Exited(101),
    )
    assert_true(output.to_string().contains("tls_connections=1"))
  }
}
