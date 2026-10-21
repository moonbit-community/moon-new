///|
pub fn os_path(path : String) -> Bytes raise OSError {
  if path.contains_char('\u0000') {
    raise OSError(if platform is Windows { 87 } else { 22 }, context="path")
  }
  if platform is Windows {
    @utf16.encode(path, endianness=Little, bom=false) + b"\x00\x00"
  } else {
    @utf8.encode(path) + b"\x00"
  }
}

///|
pub extern "C" fn standard_fd(id : Int32) -> Fd = "moonrun_native_standard_fd"

///|
pub extern "C" fn sleep(milliseconds : Int32) -> Unit = "moonrun_native_pause"

///|
pub extern "C" fn now() -> Int64 = "moonrun_native_now"

///|
fn if_nametoindex(name : StringView, context~ : String) -> UInt32 raise {
  let socket = make_udp_socket(4, false)
  if socket_invalid(socket) {
    check_errno(context)
  }
  defer close_socket(socket)
  let index = interface_index(socket, os_path(name.to_owned()))
  if index == 0 {
    check_errno(context)
  }
  index
}

///|
fn if_indextoname(index : UInt32, context~ : String) -> String raise {
  let socket = make_udp_socket(4, false)
  if socket_invalid(socket) {
    check_errno(context)
  }
  defer close_socket(socket)
  let bytes = interface_name(socket, index)
  if bytes.is_empty() {
    check_errno(context)
  }
  if platform is Windows {
    @utf16.decode_lossy(bytes[:bytes.length() - 2], endianness=Little)
  } else {
    @utf8.decode_lossy(bytes[:bytes.length() - 1])
  }
}
