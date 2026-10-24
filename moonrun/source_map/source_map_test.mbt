///|
test "maps module offsets to the preceding source position" {
  guard @source_map.SourceMap::parse(
      (
        #|{"sources":["main.mbt","lib.mbt"],"mappings":"AAAA,UCCA,UDDA"}
      ),
    )
    is Some(map) else {
    fail("valid source map rejected")
  }
  assert_true(map.position(-1L) is None)
  assert_true(map.position(0L) is Some({ file: "main.mbt", line: 1, }))
  assert_true(map.position(9L) is Some({ file: "main.mbt", line: 1, }))
  assert_true(map.position(10L) is Some({ file: "lib.mbt", line: 2, }))
  assert_true(map.position(20L) is Some({ file: "main.mbt", line: 1, }))
  assert_eq(
    @source_map.format_frame("leaf", Some(10L), Some(map)),
    "at leaf lib.mbt:2",
  )
  assert_eq(@source_map.format_frame("leaf", None, Some(map)), "at leaf")
  assert_eq(@source_map.format_frame("leaf", Some(10L), None), "at leaf")
}

///|
test "source map handling ignores absent locations and rejects malformed data" {
  guard @source_map.SourceMap::parse(
      (
        #|{"sources":["main.mbt"],"mappings":"KAAA;AAAA"}
      ),
    )
    is Some(map) else {
    fail("valid source map rejected")
  }
  assert_true(map.position(4L) is None)
  assert_true(map.position(5L) is Some({ file: "main.mbt", line: 1, }))
  for
    text in [
      "not json",
      "{}",
      (
        #|{"sources":[1],"mappings":""}
      ),
      (
        #|{"sources":[],"mappings":"AAAA"}
      ),
      (
        #|{"sources":["main.mbt"],"mappings":"?"}
      ),
      (
        #|{"sources":["main.mbt"],"mappings":"g"}
      ),
      (
        #|{"sources":["main.mbt"],"mappings":"gggggggggggggA"}
      ),
      (
        #|{"sources":["main.mbt"],"mappings":"DAAA"}
      ),
      (
        #|{"sources":["main.mbt"],"mappings":"AADA"}
      ),
      (
        #|{"sources":["main.mbt"],"mappings":"KAAA,DAAA"}
      ),
    ] {
    assert_true(@source_map.SourceMap::parse(text) is None, msg=text)
  }
}

///|
fn append_leb(output : Array[Byte], value : Int32) -> Unit {
  let mut value = value
  while value >= 128 {
    output.push(((value & 0x7F) | 0x80).to_byte())
    value = value >> 7
  }
  output.push(value.to_byte())
}

///|
fn wasm_with_url(url : Bytes) -> Bytes {
  let payload = [b'\x10']
  for byte in b"sourceMappingURL" {
    payload.push(byte)
  }
  append_leb(payload, url.length())
  for byte in url {
    payload.push(byte)
  }
  let output = []
  for byte in b"\x00asm\x01\x00\x00\x00\x00" {
    output.push(byte)
  }
  append_leb(output, payload.length())
  for byte in payload {
    output.push(byte)
  }
  Bytes::from_array(output)
}

///|
test "loads local relative and absolute URLs without using the process cwd" {
  let directory = @sys.tmpdir(prefix="moonrun-source-map-")
  defer @sys.rmdir(directory, recursive=true) |> ignore
  let wasm = directory + "/program.wasm"
  let source =
    #|{"sources":["源码.mbt"],"mappings":"AAAA"}
  @sys.write_file(directory + "/symbols.map", @utf8.encode(source))
  for url in ["symbols.map", directory + "/symbols.map"] {
    guard @source_map.SourceMap::load(wasm, wasm_with_url(@utf8.encode(url)))
      is Some(map) else {
      fail("failed to load local map")
    }
    assert_true(map.position(0L) is Some({ file: "源码.mbt", line: 1, }))
  }
  assert_true(
    @source_map.SourceMap::load(wasm, wasm_with_url(b"missing.map")) is None,
  )
  if !(@sys.platform is Windows) {
    @sys.mkdir(directory + "/real/deep", recursive=true)
    @sys.symlink(target=directory + "/real/deep", directory + "/link")
    @sys.write_file(directory + "/real/symbols.map", @utf8.encode(source))
    guard @source_map.SourceMap::load(
        directory + "/link/program.wasm",
        wasm_with_url(b"../symbols.map"),
      )
      is Some(map) else {
      fail("source map path was normalized across a symlink")
    }
    assert_true(map.position(0L) is Some({ file: "源码.mbt", line: 1, }))
  }
}

///|
test "missing remote and malformed URLs fall back to the adjacent map" {
  let directory = @sys.tmpdir(prefix="moonrun-source-map-")
  defer @sys.rmdir(directory, recursive=true) |> ignore
  let wasm = directory + "/program.wasm"
  let empty_wasm = b"\x00asm\x01\x00\x00\x00"
  assert_true(@source_map.SourceMap::load(wasm, empty_wasm) is None)
  @sys.write_file(wasm + ".map", b"not json")
  assert_true(@source_map.SourceMap::load(wasm, empty_wasm) is None)
  @sys.write_file(
    wasm + ".map",
    b"{\"sources\":[\"main.mbt\"],\"mappings\":\"AAAA\"}",
  )
  for
    bytes in [
      empty_wasm,
      wasm_with_url(b""),
      wasm_with_url(b"https://example.invalid/program.map"),
      wasm_with_url(b"http://example.invalid/program.map"),
      wasm_with_url(b"data:application/json;base64,e30="),
      wasm_with_url(b"\xFF"),
      b"\x00asm\x01\x00\x00\x00\x00\xFF\xFF\xFF\xFF\x10",
      b"\x00asm\x01\x00\x00\x00\x00\x05\x10",
      b"\x00asm\x01\x00\x00\x00\x00\x01\x80",
    ] {
    guard @source_map.SourceMap::load(wasm, bytes) is Some(map) else {
      fail("failed to load fallback map")
    }
    assert_eq(
      @source_map.format_frame("leaf", Some(0L), Some(map)),
      "at leaf main.mbt:1",
    )
  }
}
