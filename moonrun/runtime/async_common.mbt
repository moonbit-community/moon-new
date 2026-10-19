///|
extern "C" fn native_error_message(code : Int32) -> Bytes = "moonrun_error_message"

///|
extern "C" fn native_pid() -> Int32 = "moonbitlang_async_getpid"

///|
fn native_string(
  buffer : FixedArray[Byte],
  offset : Int32,
  length : Int32,
) -> String raise @vm.RuntimeError {
  guard offset >= 0 && offset <= buffer.length() else {
    raise @vm.OutOfBoundsMemoryAccess
  }
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
    guard offset + length + width <= buffer.length() else {
      raise @vm.OutOfBoundsMemoryAccess
    }
  }
  check_range(offset, length, buffer.length())
  let bytes = Bytes::from_array(buffer[offset:offset + length])
  if @async.platform is Windows {
    guard length % 2 == 0 else { raise @vm.TypeMismatch }
    @utf16.decode_lossy(bytes, endianness=Little)
  } else {
    @utf8.decode_lossy(bytes)
  }
}

///|
fn Host::common_async_import(
  self : Host,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  match name {
    "env_util/getpid" => [I32(native_pid())]
    "runtime/get_platform" =>
      [
        I32(
          match @async.platform {
            Linux => 0
            MacOS => 1
            Windows => 2
          },
        ),
      ]
    "runtime/exit" | "runtime/terminate_process_by_signal" => {
      let value = i32(args[0])
      if name == "runtime/exit" {
        self.exit_code = Some(value)
      } else {
        self.termination_signal = Some(value)
      }
      raise @vm.HostExit(value)
    }
    // Native async owns the process-wide Winsock reference. Guest loop teardown
    // must not call WSACleanup and invalidate the embedding host's sockets.
    "runtime/init_WSA" | "runtime/cleanup_WSA" => [I32(0)]
    "os_error/get_ENOTDIR" => [I32(@os_error.errno_ENOTDIR)]
    "os_error/get_ENOTSUP" => [I32(@os_error.errno_ENOTSUP)]
    "os_error/errno_to_string" => {
      let bytes = native_error_message(i32(args[0]))
      let handle = self.next_handle
      self.next_handle += 1L
      self.buffers[handle] = bytes.to_fixedarray()
      [I64(handle)]
    }
    "os_error/free_errno_str" => {
      self.buffers.remove(i64(args[0]))
      []
    }
    "os_string/decode_len" | "os_string/decode" => {
      guard self.buffers.get(i64(args[0])) is Some(buffer) else {
        raise @vm.TypeMismatch
      }
      let text = native_string(buffer, i32(args[1]), i32(args[2]))
      if name == "os_string/decode_len" {
        return [I32(text.length())]
      }
      guard i32(args[4]) == text.length() else { raise @vm.TypeMismatch }
      let memory = guest_memory(caller)
      let pointer = i32(args[3]).reinterpret_as_uint().to_int64()
      guard pointer + text.length().to_int64() * 2L <= memory.byte_len() else {
        raise @vm.OutOfBoundsMemoryAccess
      }
      for index in 0..<text.length() {
        memory.store_i64_16_at(
          pointer + index.to_int64() * 2L,
          text.code_unit_at(index).to_int64(),
        )
      }
      []
    }
    "stdio/get_stdio_handle" => {
      let id = i32(args[0])
      guard id >= 0 && id <= 2 else {
        self.async_errno = bad_fd_errno
        return [I64(0L)]
      }
      self.suspend(() => {
        if self.stdio_handles.get(id) is Some(handle) &&
          self.fds.contains(handle) {
          return [I64(handle)]
        }
        let fd = if (id == 0 && self.stdin is Some(_)) ||
          (id == 1 && self.stdout is Some(_)) ||
          (id == 2 && self.stderr is Some(_)) {
          invalid_native_fd()
        } else if id == 0 {
          @stdio.stdin.fd()
        } else if id == 1 {
          @stdio.stdout.fd()
        } else {
          @stdio.stderr.fd()
        }
        let handle = self.next_handle
        self.next_handle += 1L
        self.fds[handle] = GuestFd(Standard(id, fd))
        self.stdio_handles[id] = handle
        [I64(handle)]
      })
    }
    "fd_util/kind_of_fd" => {
      guard self.fds.get(i64(args[0])) is Some(fd) else {
        self.async_errno = bad_fd_errno
        return [I32(-1)]
      }
      self.suspend(() => {
        if fd.owner is Standard(id, _) &&
          (
            (id == 0 && self.stdin is Some(_)) ||
            (id == 1 && self.stdout is Some(_)) ||
            (id == 2 && self.stderr is Some(_))
          ) {
          return [I32(5)]
        }
        let stat = packed_stat(fd.native(), 1, 16)
        guard stat is [u32le(_), u32le(1), i64le(kind)] else {
          raise @vm.TypeMismatch
        }
        [I32(kind.to_int())]
      })
    }
    name if name.has_prefix("os_error/is_") => {
      let error = @os_error.OSError(i32(args[0]), context="")
      let value = match name {
        "os_error/is_nonblocking_io_error" => error.is_nonblocking_io_error()
        "os_error/is_EINTR" => error.is_EINTR()
        "os_error/is_ENOENT" => error.is_ENOENT()
        "os_error/is_EEXIST" => error.is_EEXIST()
        "os_error/is_EACCES" => error.is_EACCES()
        "os_error/is_ECONNREFUSED" => error.is_ECONNREFUSED()
        "os_error/is_ERROR_NOTIFY_ENUM_DIR" => error.is_ERROR_NOTIFY_ENUM_DIR()
        _ => raise @vm.UnknownImport("moonbitlang/async", name)
      }
      [I32(if value { 1 } else { 0 })]
    }
    _ => self.signal_import(caller, name, args)
  }
}

///|
fn common_async_signature(name : String) -> @wasm.FuncType? {
  let (params, results) : (
    ReadOnlyArray[@wasm.ValueType],
    ReadOnlyArray[@wasm.ValueType],
  ) = match name {
    "env_util/getpid" => ([], [I32])
    "runtime/get_platform"
    | "runtime/init_WSA"
    | "runtime/cleanup_WSA"
    | "os_error/get_ENOTDIR"
    | "os_error/get_ENOTSUP" => ([], [I32])
    "runtime/exit" | "runtime/terminate_process_by_signal" => ([I32], [])
    "os_error/errno_to_string" | "stdio/get_stdio_handle" => ([I32], [I64])
    "os_error/free_errno_str" => ([I64], [])
    "fd_util/kind_of_fd" => ([I64], [I32])
    "os_string/decode_len" => ([I64, I32, I32], [I32])
    "os_string/decode" => ([I64, I32, I32, I32, I32], [])
    "signal/get_signal_by_index" | "signal/set_console_control_handler" =>
      ([I32], [I32])
    "signal/set_global_cancellation_signals" => ([I32, I32, I32, I32], [])
    "signal/start_signal_handler" | "signal/terminate_signal_handler" =>
      ([], [])
    "os_error/is_nonblocking_io_error"
    | "os_error/is_EINTR"
    | "os_error/is_ENOENT"
    | "os_error/is_EEXIST"
    | "os_error/is_EACCES"
    | "os_error/is_ECONNREFUSED"
    | "os_error/is_ERROR_NOTIFY_ENUM_DIR" => ([I32], [I32])
    _ => return None
  }
  Some({ params, results, })
}
