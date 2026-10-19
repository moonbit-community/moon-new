///|
async test "policies reject unknown fields and malformed authorization rules" {
  for
    source in [
      "{\"unknown\":{}}", "{\"fs\":{\"read\":null}}", "{\"net\":{\"bind\":[\"localhost:*\"]}}",
      "{\"net\":{\"connect\":[\"*:65536\"]}}", "{\"process\":{\"spawn\":null}}",
      "{\"process\":{\"spawn\":true,\"allow\":[{\"program\":\"sh\"}]}}", "{\"process\":{\"allow\":[{\"program\":\"\"}]}}",
      "{\"env\":{\"set\":{\"A=B\":\"value\"}}}", "{\"env\":{\"set\":{\"A\":\"nul\\u0000value\"}}}",
    ] {
    let rejected = try {
      ignore(@runtime.Policy::from_json(source))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
async test "policy environment provisioning starts empty and is isolated per run" {
  let source =
    #|(module
    #| (import "__moonbit_fs_unstable" "get_env_var_exists" (func $exists (param externref) (result i32)))
    #| (import "__moonbit_fs_unstable" "get_env_var" (func $get (param externref) (result externref)))
    #| (import "wasm:js-string" "equals" (func $equals (param externref externref) (result i32)))
    #| (import "_" "SECRET" (global $secret externref))
    #| (import "_" "COPIED" (global $copied externref))
    #| (import "_" "SET" (global $set externref))
    #| (import "_" "host value" (global $host externref))
    #| (import "_" "policy value" (global $value externref))
    #| (func (export "_start")
    #|   global.get $secret call $exists if unreachable end
    #|   global.get $copied call $get global.get $host call $equals i32.eqz if unreachable end
    #|   global.get $set call $get global.get $value call $equals i32.eqz if unreachable end))
  let policy = @runtime.Policy::from_json(
    "{\"env\":{\"from_host\":[\"COPIED\"],\"set\":{\"SET\":\"policy value\"}}}",
  )
  let host = { "SECRET": "hidden", "COPIED": "host value" }
  assert_eq(compile(source).run(policy~, env=host), Completed)
  assert_eq(host.get("SECRET"), Some("hidden"))
  assert_eq(host.get("SET"), None)
}

///|
async test "file policy permits one canonical root and blocks outside targets" {
  let directory = @fs.tmpdir(prefix="moonrun-policy-")
  defer @fs.rmdir(directory, recursive=true) |> ignore
  @fs.mkdir(directory + "/allowed")
  @fs.write_file(directory + "/allowed/input", "permitted")
  @fs.write_file(directory + "/outside", "secret")
  let source =
    #|(module
    #| (import "__moonbit_fs_unstable" "read_file_to_bytes_new" (func $read (param externref) (result i32)))
    #| (import "__moonbit_fs_unstable" "write_bytes_to_file_new" (func $write (param externref externref) (result i32)))
    #| (import "__moonbit_fs_unstable" "begin_create_byte_array" (func $bytes (result externref)))
    #| (import "__moonbit_fs_unstable" "finish_create_byte_array" (func $finish (param externref) (result externref)))
    #| (import "_" "allowed/input" (global $allowed externref))
    #| (import "_" "outside" (global $outside externref))
    #| (import "_" "allowed/../outside" (global $traversal externref))
    #| (import "_" "allowed/new" (global $new externref))
    #| (func (export "_start")
    #|   global.get $allowed call $read if unreachable end
    #|   global.get $outside call $read i32.const -1 i32.ne if unreachable end
    #|   global.get $traversal call $read i32.const -1 i32.ne if unreachable end
    #|   global.get $new call $bytes call $finish call $write if unreachable end))
  let policy = @runtime.Policy::from_json(
    "{\"fs\":{\"read\":[\"allowed\"],\"write\":[\"allowed\"]}}",
    source_dir=directory,
  )
  let diagnostics : Array[Byte] = []
  assert_eq(
    compile(source).run(cwd=directory, policy~, stderr=bytes => {
      diagnostics.push_iter(bytes.iter())
    }),
    Completed,
  )
  assert_eq(@fs.read_file(directory + "/outside").text(), "secret")
  assert_true(@fs.exists(directory + "/allowed/new"))
  assert_true(
    @utf8.decode(Bytes::from_array(diagnostics)).contains(
      "Sandbox policy blocked file read",
    ),
  )
}

///|
async test "socket bind denial returns errno and permitted bind executes once" {
  let source =
    #|(module
    #| (import "moonbitlang/async" "socket/make_udp_socket" (func $socket (param i32 i32) (result i64)))
    #| (import "moonbitlang/async" "socket/init_ip_addr" (func $addr (param i32 i32 i32)))
    #| (import "moonbitlang/async" "socket/ipv4_addr_size" (func $size (result i32)))
    #| (import "moonbitlang/async" "socket/bind" (func $bind (param i64 i32 i32) (result i32)))
    #| (import "moonbitlang/async" "os_error/get_errno" (func $errno (result i32)))
    #| (memory (export "memory") 1)
    #| (func (export "_start")
    #|   i32.const 0 i32.const 2130706433 i32.const 0 call $addr
    #|   i32.const 4 i32.const 0 call $socket i32.const 0 call $size call $bind EXPECT))
  let denied = @runtime.Policy::from_json("{}")
  let denied_program = compile(
    source
    .replace(
      old="EXPECT",
      new="i32.const -1 i32.ne if unreachable end call $errno i32.const PERMISSION i32.ne if unreachable end",
    )
    .replace(
      old="PERMISSION",
      new=if @async.platform is Windows { "5" } else { "13" },
    ),
  )
  assert_eq(denied_program.run(policy=denied, stderr=_ => ()), Completed)
  let allowed = @runtime.Policy::from_json(
    "{\"net\":{\"bind\":[\"127.0.0.1:0\"]}}",
  )
  assert_eq(
    compile(source.replace(old="EXPECT", new="if unreachable end")).run(
      policy=allowed,
    ),
    Completed,
  )
}

///|
async test "recursive removal unlinks a root symlink without deleting its target" {
  let directory = @fs.tmpdir(prefix="moonrun-policy-link-")
  defer @fs.rmdir(directory, recursive=true) |> ignore
  @fs.mkdir(directory + "/allowed")
  @fs.mkdir(directory + "/outside")
  @fs.write_file(directory + "/outside/sentinel", "preserved")
  let policy = @runtime.Policy::from_json(
    "{\"fs\":{\"write\":[\"allowed\"]}}",
    source_dir=directory,
  )
  let source =
    #|(module
    #| (import "__moonbit_fs_unstable" "remove_dir_new" (func $remove (param externref) (result i32)))
    #| (import "_" "allowed/link" (global $path externref))
    #| (func (export "_start") global.get $path call $remove if unreachable end))
  for suffix in ["", "/", "////"] {
    @fs.symlink(target=directory + "/outside", directory + "/allowed/link")
    let program = compile(
      source.replace(old="allowed/link", new="allowed/link" + suffix),
    )
    assert_eq(program.run(cwd=directory, policy~), Completed)
    assert_eq(
      @fs.read_file(directory + "/outside/sentinel").text(),
      "preserved",
    )
    assert_true(!@fs.exists(directory + "/allowed/link"))
  }
}
