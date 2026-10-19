///|
pub extern "C" fn native_error_message(code : Int32) -> Bytes = "moonrun_error_message"

///|
pub extern "C" fn native_pid() -> Int32 = "moonbitlang_async_getpid"

///|
pub fn native_string(
  buffer : FixedArray[Byte],
  offset : Int32,
  length : Int32,
) -> String raise HostError {
  guard offset >= 0 && offset <= buffer.length() else { raise Bounds }
  let mut length = length
  if length == -1 {
    let width = if @async.platform is Windows { 2 } else { 1 }
    length = 0
    while offset + length + width <= buffer.length() {
      if buffer[offset + length] == b'\x00' &&
        (width == 1 || buffer[offset + length + 1] == b'\x00') {
        break
      }
      length += width
    }
    guard offset + length + width <= buffer.length() else { raise Bounds }
  }
  check_range(offset, length, buffer.length())
  let bytes = Bytes::from_array(buffer[offset:offset + length])
  if @async.platform is Windows {
    guard length % 2 == 0 else { raise Invalid }
    @utf16.decode_lossy(bytes, endianness=Little)
  } else {
    @utf8.decode_lossy(bytes)
  }
}
