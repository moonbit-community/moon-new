///|
fn parse_test_selection(
  selection : String,
) -> Array[(String, Array[(UInt32, UInt32)])] raise {
  let json = @json.parse(selection)
  guard json is { "package": String(_), "file_and_index": Array(files), .. } else {
    raise @vm.LinkErrorDetail(
      "invalid MoonBit test arguments: expected package and file_and_index",
    )
  }
  let selected = []
  for file in files {
    guard file is [String(name), Array(ranges)] else {
      raise @vm.LinkErrorDetail("invalid MoonBit test file selection")
    }
    let indices = []
    for range in ranges {
      guard range is { "start": Number(start, ..), "end": Number(end, ..), .. } &&
        start >= 0 &&
        end >= 0 &&
        start <= 4294967295 &&
        end <= 4294967295 &&
        start == start.to_uint().to_double() &&
        end == end.to_uint().to_double() else {
        raise @vm.LinkErrorDetail("invalid MoonBit test index range")
      }
      indices.push((start.to_uint(), end.to_uint()))
    }
    selected.push((name, indices))
  }
  selected
}
