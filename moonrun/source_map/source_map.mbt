// Ported from Rust moonrun's source_map.rs at 80b2d6c8 (Apache-2.0).

///|
struct Mapping {
  address : Int64
  source : Int32
  line : Int32
}

///|
/// Address-oriented source maps emitted by moon_wat2wasm.
pub struct SourceMap {
  priv sources : Array[String]
  priv mappings : Array[Mapping]
}

///|
pub(all) struct SourcePosition {
  file : String
  line : Int32
}

///|
/// Parse optional diagnostic metadata. Malformed maps are ignored.
pub fn SourceMap::parse(text : String) -> SourceMap? {
  let json = @json.parse(text) catch { _ => return None }
  guard json is { "sources": Array(sources), "mappings": String(encoded), .. } else {
    return None
  }
  let files = []
  for source in sources {
    guard source is String(file) else { return None }
    files.push(file)
  }
  let mappings : Array[Mapping] = []
  let mut source = 0L
  let mut line = 0L
  for generated_line, segments in encoded.split(";") {
    let mut address = 0L
    for segment in segments.split(",") {
      if segment.is_empty() {
        continue
      }
      guard decode_vlq(segment) is Some([delta, .. rest]) else { return None }
      address += delta
      guard address >= 0L && address <= 0xFFFFFFFFL else { return None }
      if rest is [source_delta, line_delta, _, ..] {
        source += source_delta
        line += line_delta
        guard source >= 0L &&
          source < files.length().to_int64() &&
          line >= 0L &&
          line < 2147483647L else {
          return None
        }
        if generated_line == 0 {
          if mappings.last() is Some(previous) && address < previous.address {
            return None
          }
          mappings.push({
            address,
            source: source.to_int(),
            line: line.to_int() + 1,
          })
        }
      }
    }
  }
  Some({ sources: files, mappings, })
}

///|
/// Find the last mapping at or before a Wasm module byte offset.
pub fn SourceMap::position(self : SourceMap, offset : Int64) -> SourcePosition? {
  let mut low = 0
  let mut high = self.mappings.length()
  while low < high {
    let middle = low + (high - low) / 2
    if self.mappings[middle].address <= offset {
      low = middle + 1
    } else {
      high = middle
    }
  }
  guard low > 0 else { return None }
  let mapping = self.mappings[low - 1]
  Some({ file: self.sources[mapping.source], line: mapping.line, })
}

///|
/// Render a frame with a source location only for a known Wasm module offset.
pub fn format_frame(
  function : String,
  module_offset : Int64?,
  source_map : SourceMap?,
) -> String {
  if source_map is Some(map) &&
    module_offset is Some(offset) &&
    map.position(offset) is Some(position) {
    "at \{function} \{position.file}:\{position.line}"
  } else {
    "at \{function}"
  }
}

///|
fn decode_vlq(segment : StringView) -> Array[Int64]? {
  let result = []
  let mut value = 0UL
  let mut shift = 0
  for c in segment {
    let digit = match c {
      'A'..<='Z' => c.to_int() - 'A'.to_int()
      'a'..<='z' => c.to_int() - 'a'.to_int() + 26
      '0'..<='9' => c.to_int() - '0'.to_int() + 52
      '+' => 62
      '/' => 63
      _ => return None
    }
    let payload = digit & 31
    guard shift <= 60 && (shift < 60 || payload <= 7) else { return None }
    value = value | (payload.to_uint64() << shift)
    if (digit & 32) == 0 {
      let magnitude = (value >> 1).reinterpret_as_int64()
      result.push(if (value & 1UL) == 0UL { magnitude } else { -magnitude })
      value = 0UL
      shift = 0
    } else {
      shift += 5
    }
  }
  if shift == 0 {
    Some(result)
  } else {
    None
  }
}

///|
/// Load a local sourceMappingURL, or fall back to <wasm_path>.map.
/// Source maps are optional: missing files and invalid data do not prevent runs.
pub fn SourceMap::load(wasm_path : String, bytes : Bytes) -> SourceMap? {
  let map_path = match source_mapping_url(bytes) {
    Some(url) if !url.is_empty() &&
      !url.has_prefix("data:") &&
      !url.has_prefix("http://") &&
      !url.has_prefix("https://") => {
      let path = @path.Path(url)
      if path.is_absolute() {
        url
      } else {
        @path.Path(
          // Preserve symlinks followed by `..`; Path::join normalizes them.
          wasm_path,
        )
        .dirname()
        .to_string() +
        "/" +
        url
      }
    }
    _ => wasm_path + ".map"
  }
  let text = @sys.read_file_to_string(map_path) catch { _ => return None }
  SourceMap::parse(text)
}

///|
fn source_mapping_url(bytes : Bytes) -> String? {
  guard bytes.length() >= 8 && bytes[:8] == b"\x00asm\x01\x00\x00\x00" else {
    return None
  }
  let mut position = 8
  while position < bytes.length() {
    let section = bytes[position]
    guard read_u32_leb(bytes[:], position + 1) is Some((length, start)) &&
      length <= (bytes.length() - start).to_int64() else {
      return None
    }
    let end = start + length.to_int()
    if section == b'\x00' {
      let payload = bytes[start:end]
      guard read_u32_leb(payload, 0) is Some((name_length, name_start)) &&
        name_length <= (payload.length() - name_start).to_int64() else {
        return None
      }
      let name_end = name_start + name_length.to_int()
      if payload[name_start:name_end] == b"sourceMappingURL" {
        guard read_u32_leb(payload, name_end) is Some((url_length, url_start)) &&
          url_length <= (payload.length() - url_start).to_int64() else {
          return None
        }
        return Some(
          @utf8.decode(payload[url_start:url_start + url_length.to_int()]),
        ) catch {
          _ => None
        }
      }
    }
    position = end
  }
  None
}

///|
fn read_u32_leb(bytes : BytesView, start : Int32) -> (Int64, Int32)? {
  let mut value = 0L
  for index in 0..<5 {
    guard bytes.get(start + index) is Some(byte) else { return None }
    let byte = byte.to_int()
    guard index < 4 || (byte & 0xF0) == 0 else { return None }
    value = value | ((byte & 0x7F).to_int64() << (index * 7))
    if (byte & 0x80) == 0 {
      return Some((value, start + index + 1))
    }
  }
  None
}
