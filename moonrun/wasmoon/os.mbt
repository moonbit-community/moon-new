///|
fn Context::common_async_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.async_host
  match name {
    "tls/connection/free" => {
      // Releasing a null connection requires no TLS session implementation.
      guard i64(args[0]) == self.runtime.handles.null_handle else {
        raise @sys.Operation("Badf")
      }
      []
    }
    "env_util/getpid" => [I32(@sys.native_pid())]
    "runtime/get_platform" =>
      [
        I32(
          match @sys.platform {
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
        host.termination_signal = Some(value)
      }
      raise @vm.HostExit(value)
    }
    // Native async owns the process-wide Winsock reference. Guest loop teardown
    // must not call WSACleanup and invalidate the embedding host's sockets.
    "runtime/init_WSA" | "runtime/cleanup_WSA" => [I32(0)]
    "os_error/get_ENOTDIR" => [I32(@sys.errno_ENOTDIR)]
    "os_error/get_ENOTSUP" => [I32(@sys.errno_ENOTSUP)]
    "os_error/errno_to_string" => {
      let bytes = @sys.native_error_message(i32(args[0]))
      let handle = self.runtime.handles.allocate()
      host.buffers[handle] = bytes.to_fixedarray()
      [I64(handle)]
    }
    "os_error/free_errno_str" => {
      host.buffers.remove(i64(args[0]))
      []
    }
    "os_string/decode_len" | "os_string/decode" => {
      guard host.buffers.get(i64(args[0])) is Some(buffer) else {
        raise @vm.TypeMismatch
      }
      let text = @sys.native_string(buffer, i32(args[1]), i32(args[2]))
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
        host.async_errno = @sys.bad_fd_errno
        return [I64(self.runtime.handles.invalid_fd)]
      }
      if host.stdio_handles.get(id) is Some(handle) && host.fds.contains(handle) {
        return [I64(handle)]
      }
      let fd = if (id == 0 && self.runtime.stdio.stdin is Some(_)) ||
        (id == 1 && self.runtime.stdio.stdout is Some(_)) ||
        (id == 2 && self.runtime.stdio.stderr is Some(_)) {
        @sys.invalid_native_fd()
      } else if id == 0 {
        @sys.stdin.fd()
      } else if id == 1 {
        @sys.stdout.fd()
      } else {
        @sys.stderr.fd()
      }
      let handle = self.runtime.handles.allocate()
      host.fds[handle] = @resource.Resource(Standard(id, fd))
      host.stdio_handles[id] = handle
      [I64(handle)]
    }
    "fd_util/kind_of_fd" => {
      guard host.fds.get(i64(args[0])) is Some(fd) else {
        host.async_errno = @sys.bad_fd_errno
        return [I32(-1)]
      }
      if fd.owner is Standard(id, _) &&
        (
          (id == 0 && self.runtime.stdio.stdin is Some(_)) ||
          (id == 1 && self.runtime.stdio.stdout is Some(_)) ||
          (id == 2 && self.runtime.stdio.stderr is Some(_))
        ) {
        return [I32(5)]
      }
      let stat = @native_jobs.packed_stat(fd.native(), 1, 16)
      guard stat is [u32le(_), u32le(1), i64le(kind)] else {
        raise @vm.TypeMismatch
      }
      [I32(kind.to_int())]
    }
    name if name.has_prefix("os_error/is_") => {
      let error = @sys.OSError(i32(args[0]), context="")
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
    "tls/connection/free" => ([I64], [])
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
