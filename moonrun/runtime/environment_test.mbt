// Compatibility regressions; original probes from moon/crates/moonrun/tests at 12e9d22e.

///|
async test "console accepts non-null externref arguments" {
  let source =
    #|(module
    #| (import "console" "log" (func $log (param (ref extern))))
    #| (import "_" "hello" (global $hello externref))
    #| (func (export "_start") global.get $hello ref.as_non_null call $log))
  let output = StringBuilder()
  assert_eq(
    compile(source).run(stdout=bytes => {
      output.write_string(@utf8.decode_lossy(bytes))
    }),
    Completed,
  )
  assert_eq(output.to_string(), "hello\n")
}

///|
async test "host signature adaptation still rejects incompatible types" {
  for
    source in [
      "(module (import \"console\" \"log\" (func (param i64))))", "(module (import \"ffi-bytes\" \"set\" (func (param externref i32 i32) (result i64))))",
    ] {
    let rejected = try {
      compile(source).run() |> ignore
      false
    } catch {
      @vm.LinkErrorDetail(_) => true
      error => raise error
    }
    assert_true(rejected)
  }
}

///|
async test "in-memory module names do not supply an executable origin" {
  let source =
    #|(module
    #| (import "moonbitlang/async" "c_buffer/is_null" (func $null (param i64) (result i32)))
    #| (import "moonbitlang/core" "env/current_exe" (func $exe (result i64)))
    #| (import "moonbitlang/core" "env/current_exe_dir" (func $dir (result i64)))
    #| (import "moonbitlang/async" "os_error/get_errno" (func $errno (result i32)))
    #| (func (export "_start")
    #|   call $exe call $null i32.eqz if unreachable end
    #|   call $errno i32.const INVALID i32.ne if unreachable end
    #|   call $dir call $null i32.eqz if unreachable end
    #|   call $errno i32.const INVALID i32.ne if unreachable end))
  let bytes = @encoder.encode(
    @wat.parse(
      source
      .split("INVALID")
      .join(if @async.platform is Windows { "87" } else { "22" }),
    ),
  ).map(byte => byte.to_byte())
  assert_eq(
    @runtime.Module::from_bytes(
      Bytes::from_array(bytes),
      name="existing-looking-file.wasm",
    ).run(),
    Completed,
  )
}

///|
async test "file-backed executable origin survives removal and a different run cwd" {
  let directory = @fs.tmpdir(prefix="moonrun-origin-")
  defer @fs.rmdir(directory, recursive=true) |> ignore
  @fs.mkdir(directory + "/other")
  let path = directory + "/café.wasm"
  let source = StringBuilder()
  source.write_string(
    (
      #|(module
      #| (import "moonbitlang/core" "env/current_exe" (func $exe (result i64)))
      #| (import "moonbitlang/core" "env/current_exe_dir" (func $dir (result i64)))
      #| (import "moonbitlang/async" "c_buffer/length" (func $len (param i64) (result i32)))
      #| (import "moonbitlang/async" "c_buffer/c_buffer_get" (func $get (param i64 i32) (result i32)))
      #| (import "moonbitlang/async" "c_buffer/free" (func $free (param i64)))
      #| (func (export "_start") (local $buffer i64)
    ),
  )
  for (name, expected) in [("exe", path), ("dir", directory)] {
    let bytes = if @async.platform is Windows {
      @utf16.encode(expected + "\u0000", endianness=Little, bom=false)
    } else {
      @utf8.encode(expected + "\u0000")
    }
    source.write_string(
      "call $\{name} local.tee $buffer call $len i32.const \{bytes.length()} i32.ne if unreachable end\n",
    )
    for index, byte in bytes {
      source.write_string(
        "local.get $buffer i32.const \{index} call $get i32.const \{byte.to_int()} i32.ne if unreachable end\n",
      )
    }
    source.write_string("local.get $buffer call $free\n")
  }
  source.write_string("))")
  let bytes = @encoder.encode(@wat.parse(source.to_string())).map(byte => {
    byte.to_byte()
  })
  @fs.write_file(path, Bytes::from_array(bytes))
  let program = @runtime.Module::load_file(path)
  @fs.remove(path)
  assert_eq(program.run(cwd=directory + "/other"), Completed)
}
