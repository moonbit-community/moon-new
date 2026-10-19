///|
pub fn buffer_word(
  buffer : FixedArray[Byte],
  offset : Int32,
  width : Int32,
) -> Int64 raise HostError {
  check_range(offset, width, buffer.length())
  let mut value = 0UL
  for index in 0..<width {
    value = value | (buffer[offset + index].to_uint64() << (index * 8))
  }
  value.reinterpret_as_int64()
}
