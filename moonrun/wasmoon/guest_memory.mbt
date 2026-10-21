///|
fn guest_bytes(
  caller : @vm.Caller,
  pointer : Int32,
  length : Int32,
) -> Bytes raise @vm.RuntimeError {
  let memory = guest_memory(caller)
  let address = pointer.reinterpret_as_uint().to_int64()
  guard length >= 0 && address + length.to_int64() <= memory.byte_len() else {
    raise @vm.OutOfBoundsMemoryAccess
  }
  memory.read_bytes(pointer, length)
}

///|
fn guest_string(
  caller : @vm.Caller,
  pointer : Int32,
  length : Int32,
) -> String raise @vm.RuntimeError {
  let memory = guest_memory(caller)
  let address = pointer.reinterpret_as_uint().to_int64()
  guard length >= 0 && address + length.to_int64() * 2L <= memory.byte_len() else {
    raise @vm.OutOfBoundsMemoryAccess
  }
  let builder = StringBuilder()
  let mut high = false
  for index in 0..<length {
    let unit = memory.load_i32_16u_at(address + index.to_int64() * 2L)
    if !(@sys.platform is Windows) {
      guard (if high {
        unit >= 0xDC00 && unit <= 0xDFFF
      } else {
        !(unit >= 0xDC00 && unit <= 0xDFFF)
      }) else {
        raise @vm.LinkErrorDetail("invalid UTF-16 path")
      }
      high = unit >= 0xD800 && unit <= 0xDBFF
    }
    builder.write_char(unit.unsafe_to_char())
  }
  guard !high else { raise @vm.LinkErrorDetail("invalid UTF-16 path") }
  builder.to_string()
}
