///|
fn async_signature(name : String) -> @wasm.FuncType? {
  let (params, results) : (
    ReadOnlyArray[@wasm.ValueType],
    ReadOnlyArray[@wasm.ValueType],
  ) = match name {
    "fs/get_tmp_path_len" => ([], [I32])
    "fs/get_tmp_path" => ([I32, I32], [I32])
    "fs/get_tmp_path_buffer" => ([], [I64])
    "thread_pool/init_thread_pool" => ([I64], [I64])
    "thread_pool/destroy_thread_pool" => ([], [])
    "thread_pool/make_sleep_job" => ([I32], [I64])
    "thread_pool/make_bind_job" => ([I64, I32, I32], [I64])
    "thread_pool/spawn_worker" => ([I32, I64], [I64])
    "thread_pool/wake_worker" => ([I64, I32, I64], [])
    "thread_pool/free_worker"
    | "thread_pool/worker_enter_idle"
    | "thread_pool/free_job" => ([I64], [])
    "thread_pool/cancel_worker"
    | "thread_pool/cancel_worker_with_retry"
    | "thread_pool/job_get_ret"
    | "thread_pool/job_get_err" => ([I64], [I32])
    "thread_pool/fetch_completion/unix" => ([I64, I32, I32], [I32])
    "thread_pool/errno_is_cancelled" => ([I32], [I32])
    "event_bus/create" => ([], [I64])
    "event_bus/destroy" => ([I64], [])
    "event_bus/wait" => ([I64, I32], [I32])
    "event_bus/try_register" => ([I64, I64, I32], [I32])
    "event_bus/get_event" => ([I64, I32], [I64])
    "event_bus/event_fd" => ([I64], [I64])
    "event_bus/event_events/unix" => ([I64], [I32])
    "event_bus/event_bytes_transferred/windows" => ([I64], [I32])
    "event_bus/event_io_result/windows" => ([I64], [I64])
    "event_bus/event_pid" => ([I64], [I32])
    "fd_util/pipe" => ([I32, I32, I32, I32], [I32])
    "fd_util/close_fd" => ([I64], [I32])
    "fd_util/set_cloexec" => ([I64], [I32])
    "fd_util/invalid_fd" => ([], [I64])
    "io/read/unix" | "io/write/unix" => ([I64, I32, I32, I32], [I32])
    "time/get_ms_since_epoch" => ([], [I64])
    "os_error/get_errno" => ([], [I32])
    "c_buffer/new" => ([I32], [I64])
    "c_buffer/free" => ([I64], [])
    "c_buffer/is_null" | "c_buffer/length" | "c_buffer/strlen" => ([I64], [I32])
    "c_buffer/c_buffer_get" => ([I64, I32], [I32])
    "c_buffer/blit_to_c" | "c_buffer/blit_from_c" =>
      ([I64, I32, I32, I32, I32], [])
    // FIXME: Support TLS imports once async exposes a transport-independent
    // TLS session API: https://github.com/moonbitlang/async/issues/668
    _ => {
      for
        lookup in [
          io_result_signature, file_job_signature, directory_signature, socket_address_signature,
          socket_signature, dns_signature, socket_option_signature, process_signature,
          watcher_signature, legacy_async_signature, common_async_signature,
        ] {
        if lookup(name) is Some(signature) {
          return Some(signature)
        }
      }
      return None
    }
  }
  Some({ params, results, })
}

///|
fn i64(value : @wasm.Value) -> Int64 raise @vm.RuntimeError {
  guard value is I64(value) else { raise @vm.TypeMismatch }
  value
}

///|
fn Host::async_import(
  self : Host,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  match name {
    name if legacy_async_signature(name) is Some(_) =>
      self.legacy_async_import(caller, name, args)
    name if watcher_signature(name) is Some(_) =>
      self.watcher_import(caller, name, args)
    "fs/get_tmp_path_len" | "fs/get_tmp_path" | "fs/get_tmp_path_buffer" =>
      self.temporary_path_import(caller, name, args)
    name if process_signature(name) is Some(_) =>
      self.process_import(caller, name, args)
    name if name.has_prefix("thread_pool/") =>
      self.worker_import(caller, name, args)
    "event_bus/create"
    | "event_bus/destroy"
    | "event_bus/wait"
    | "event_bus/try_register"
    | "event_bus/get_event"
    | "event_bus/event_fd"
    | "event_bus/event_events/unix"
    | "event_bus/event_pid"
    | "event_bus/event_io_result/windows"
    | "event_bus/event_bytes_transferred/windows" =>
      self.event_bus_import(name, args)
    "fd_util/pipe"
    | "fd_util/close_fd"
    | "fd_util/set_cloexec"
    | "fd_util/invalid_fd"
    | "io/read/unix"
    | "io/write/unix" => self.pipe_import(caller, name, args)
    "time/get_ms_since_epoch" => [I64(@async.now())]
    "os_error/get_errno" => [I32(self.async_errno)]
    "c_buffer/is_null" => [I32(if i64(args[0]) == 0L { 1 } else { 0 })]
    "c_buffer/length" | "c_buffer/strlen" | "c_buffer/c_buffer_get" => {
      guard self.buffers.get(i64(args[0])) is Some(buffer) else {
        raise @vm.TypeMismatch
      }
      let value = match name {
        "c_buffer/length" => buffer.length()
        "c_buffer/c_buffer_get" => {
          let index = i32(args[1])
          check_range(index, 1, buffer.length())
          buffer[index].to_int()
        }
        _ => {
          let mut length = 0
          while length < buffer.length() && buffer[length] != b'\x00' {
            length += 1
          }
          guard length < buffer.length() else {
            raise @vm.OutOfBoundsMemoryAccess
          }
          length
        }
      }
      [I32(value)]
    }
    "c_buffer/new" => {
      let length = i32(args[0])
      guard length >= 0 else { raise @vm.OutOfBoundsMemoryAccess }
      let handle = self.next_handle
      // Do not recycle handles: a freed handle must never name a new buffer.
      self.next_handle += 1L
      self.buffers[handle] = FixedArray::make(length, b'\x00')
      [I64(handle)]
    }
    "c_buffer/free" => {
      let handle = i64(args[0])
      if handle != 0L {
        guard self.buffers.contains(handle) else { raise @vm.TypeMismatch }
        self.buffers.remove(handle)
      }
      []
    }
    "c_buffer/blit_to_c" | "c_buffer/blit_from_c" => {
      guard self.buffers.get(i64(args[0])) is Some(buffer) else {
        raise @vm.TypeMismatch
      }
      let offset = i32(args[1])
      let length = i32(args[4])
      check_range(offset, length, buffer.length())
      let memory = guest_memory(caller)
      let address = i32(args[2]).reinterpret_as_uint().to_int64() +
        i32(args[3]).reinterpret_as_uint().to_int64()
      guard address + length.to_int64() <= memory.byte_len() else {
        raise @vm.OutOfBoundsMemoryAccess
      }
      if name == "c_buffer/blit_to_c" {
        memory
        .read_bytes(address.to_int(), length)
        .to_fixedarray()
        .blit_to(buffer, dst_offset=offset, len=length)
      } else {
        memory.init_data_at(
          address,
          Bytes::from_array(buffer[offset:offset + length]),
        )
      }
      []
    }
    name if io_result_signature(name) is Some(_) =>
      self.io_result_import(caller, name, args)
    name if directory_signature(name) is Some(_) =>
      self.directory_import(name, args)
    name if socket_address_signature(name) is Some(_) =>
      self.socket_address_import(caller, name, args)
    name if socket_signature(name) is Some(_) =>
      self.windows_socket_import(caller, name, args)
    name if dns_signature(name) is Some(_) =>
      self.dns_import(caller, name, args)
    name if socket_option_signature(name) is Some(_) =>
      self.socket_option_import(caller, name, args)
    _ => self.common_async_import(caller, name, args)
  }
}
