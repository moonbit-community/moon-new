///|
let configured_policy_guest : String =
  #|(module
  #| (import "__moonbit_fs_unstable" "get_env_var" (func $get (param externref) (result externref)))
  #| (import "__moonbit_fs_unstable" "read_file_to_bytes_new" (func $read (param externref) (result i32)))
  #| (import "wasm:js-string" "equals" (func $equals (param externref externref) (result i32)))
  #| (import "_" "VALUE" (global $key externref))
  #| (import "_" "configured" (global $value externref))
  #| (import "_" "allowed/input" (global $file externref))
  #| (func (export "_start")
  #|   global.get $key call $get global.get $value call $equals i32.eqz if unreachable end
  #|   global.get $file call $read if unreachable end))

///|
test "TOML policy uses the same schema and resolves roots from its file" {
  let directory = @sys.tmpdir(prefix="moonrun-policy-toml-")
  defer @sys.rmdir(directory, recursive=true) |> ignore
  @sys.mkdir(directory + "/allowed")
  @sys.write_file(directory + "/allowed/input", "permitted")
  let path = directory + "/policy.toml"
  let content =
    #|[fs]
    #|read = ["allowed"]
    #|[env.set]
    #|VALUE = "configured"
    #|[[process.allow]]
    #|program = "echo"
    #|args_prefix = ["hello"]
  @sys.write_file(path, content)
  let policy = @runtime.Policy::load_file(path)
  assert_eq(
    compile(configured_policy_guest).run(cwd=directory, policy~),
    Completed,
  )
}

///|
test "mbtx YAML honors BOM CRLF leading blanks and an explicit source directory" {
  let directory = @sys.tmpdir(prefix="moonrun-policy-yaml-")
  defer @sys.rmdir(directory, recursive=true) |> ignore
  @sys.mkdir(directory + "/allowed")
  @sys.mkdir(directory + "/config")
  @sys.write_file(directory + "/allowed/input", "permitted")
  let path = directory + "/config/script.MbTx"
  let content =
    #|// policy:
    #|//   fs:
    #|//     read: [allowed]
    #|//   env:
    #|//     set:
    #|//       VALUE: configured
    #|//
    #|// explanation: [this is not part of the YAML
    #|///|
    #|fn main {}
  @sys.write_file(
    path,
    "\u{feff}\r\n \t\r\n" + content.split("\n").join("\r\n"),
  )
  let policy = @runtime.Policy::load_file(path, source_dir=directory)
  assert_eq(
    compile(configured_policy_guest).run(cwd=directory, policy~),
    Completed,
  )
}

///|
test "policy format selection matches JSON extensions and content sniffing" {
  let directory = @sys.tmpdir(prefix="moonrun-policy-format-")
  defer @sys.rmdir(directory, recursive=true) |> ignore
  @sys.mkdir(directory + "/allowed")
  @sys.write_file(directory + "/allowed/input", "permitted")
  let content = "{\"env\":{\"set\":{\"VALUE\":\"configured\"}},\"fs\":{\"read\":[\"allowed\"]}}"
  for name in ["policy.JsOn", "policy.conf", "policy.toml"] {
    let path = directory + "/" + name
    @sys.write_file(path, " \n" + content)
    let policy = @runtime.Policy::load_file(path)
    assert_eq(
      compile(configured_policy_guest).run(cwd=directory, policy~),
      Completed,
    )
  }
  let path = directory + "/policy.conf"
  @sys.write_file(
    path, "[env.set]\nVALUE = 'configured'\n[fs]\nread = ['allowed']",
  )
  let policy = @runtime.Policy::load_file(path)
  assert_eq(
    compile(configured_policy_guest).run(cwd=directory, policy~),
    Completed,
  )
}

///|
test "invalid policy documents fail before a guest can run" {
  let directory = @sys.tmpdir(prefix="moonrun-policy-invalid-")
  defer @sys.rmdir(directory, recursive=true) |> ignore
  for
    (name, content) in [
      ("policy.json", "[env]\nfrom_host = ['*']"),
      ("policy.json", "{\"process\":{\"spawn\":true,\"spawn\":false}}"),
      ("policy.toml", "[fs]\nread = ["),
      ("policy.toml", "[env.set]\nVALUE = 'first'\nVALUE = 'second'"),
      ("policy.toml", "[fs]\nunknown = ['*']"),
      ("policy.toml", "[process]\nspawn = 1"),
      ("policy.toml", "[env.set]\nVALUE = 1979-05-27T07:32:00Z"),
      ("script.mbtx", "// ordinary comment\n// policy: {}"),
      ("script.mbtx", "/// policy: {}"),
      ("script.mbtx", "{\"process\":{\"spawn\":true}}"),
      ("script.mbtx", "// policy:\n//   fs: ["),
      ("script.mbtx", "// policy:\n//   fs:\n//     unknown: ['*']"),
      ("script.mbtx", "// policy:\n//   process:\n//     spawn: 1"),
      ("script.mbtx", "// policy:\n//   process:\n//     spawn: 'true'"),
      ("script.mbtx", "// policy:\n//   env: !!str null"),
      (
        "script.mbtx", "// policy:\n//   process:\n//     spawn: true\n//     spawn: false",
      ),
      (
        "script.mbtx", "// policy:\n//   env: &recursive\n//     set: *recursive",
      ),
    ] {
    let path = directory + "/" + name
    @sys.write_file(path, content)
    let rejected = try {
      ignore(@runtime.Policy::load_file(path))
      false
    } catch {
      _ => true
    }
    assert_true(rejected, msg="accepted invalid \{name}: \{content}")
  }
}

///|
test "YAML string fields preserve scalar spelling and map duplicate semantics" {
  let directory = @sys.tmpdir(prefix="moonrun-policy-scalars-")
  defer @sys.rmdir(directory, recursive=true) |> ignore
  let path = directory + "/script.mbtx"
  let content =
    #|// policy:
    #|//   fs: Null
    #|//   net: ~
    #|//   process:
    #|//     allow:
    #|//       - program: 123
    #|//         args_prefix: [123, true, null, ~]
    #|//   env:
    #|//     from_host:
    #|//     set:
    #|//       HEX: 0xFF
    #|//       BOOLEAN: TRUE
    #|//       NULL: null
    #|//       EMPTY:
    #|//       TAGGED: !!bool not-a-boolean
    #|//       123: numeric key
    #|//       DUPLICATE: first
    #|//       DUPLICATE: last
  @sys.write_file(path, content)
  let policy = @runtime.Policy::load_file(path)
  let source =
    #|(module
    #| (import "__moonbit_fs_unstable" "get_env_var" (func $get (param externref) (result externref)))
    #| (import "wasm:js-string" "equals" (func $equals (param externref externref) (result i32)))
    #| (import "_" "KEY" (global $key externref))
    #| (import "_" "EXPECTED" (global $expected externref))
    #| (func (export "_start") global.get $key call $get global.get $expected call $equals i32.eqz if unreachable end))
  for
    (key, expected) in [
      ("HEX", "0xFF"),
      ("BOOLEAN", "TRUE"),
      ("NULL", "null"),
      ("EMPTY", ""),
      ("TAGGED", "not-a-boolean"),
      ("123", "numeric key"),
      ("DUPLICATE", "last"),
    ] {
    assert_eq(
      compile(
        source.replace(old="KEY", new=key).replace(old="EXPECTED", new=expected),
      ).run(policy~),
      Completed,
    )
  }
}

///|
test "YAML decoding supports aliases and empty collections with typed booleans" {
  let directory = @sys.tmpdir(prefix="moonrun-policy-alias-")
  defer @sys.rmdir(directory, recursive=true) |> ignore
  @sys.mkdir(directory + "/allowed")
  @sys.write_file(directory + "/allowed/input", "permitted")
  let path = directory + "/script.mbtx"
  let content =
    #|// policy:
    #|//   fs:
    #|//     read: &roots [allowed]
    #|//     write: *roots
    #|//   net:
    #|//     dns:
    #|//   process:
    #|//     spawn: !!str TRUE
    #|//   env:
    #|//     from_host:
    #|//     set:
    #|//       VALUE: &value configured
    #|//       COPY: *value
    #|///|
    #|fn main {}
  @sys.write_file(path, content)
  let policy = @runtime.Policy::load_file(path)
  assert_eq(
    compile(configured_policy_guest).run(cwd=directory, policy~),
    Completed,
  )
  for content in ["// policy:\n///|\nfn main {}", "// policy: {}\nfn main {}"] {
    @sys.write_file(path, content)
    let policy = @runtime.Policy::load_file(path)
    assert_eq(
      compile("(module (func (export \"_start\")))").run(policy~),
      Completed,
    )
  }
}
