///|
fn io_result_signature(name : String) -> @wasm.FuncType? {
  let (params, results) : (
    ReadOnlyArray[@wasm.ValueType],
    ReadOnlyArray[@wasm.ValueType],
  ) = match name {
    "io/make_file_read_io_result/windows" => ([I32, I64], [I64])
    "io/make_file_write_io_result/windows" => ([I32, I32, I32, I64], [I64])
    "io/make_socket_read_io_result/windows"
    | "io/make_connect_io_result/windows" => ([I32, I32], [I64])
    "io/make_socket_write_io_result/windows"
    | "io/make_socket_with_addr_read_io_result/windows" =>
      ([I32, I32, I32, I32], [I64])
    "io/make_socket_with_addr_write_io_result/windows" =>
      ([I32, I32, I32, I32, I32, I32], [I64])
    "io/make_accept_io_result/windows" => ([I32], [I64])
    "io/make_read_dir_changes_io_result/windows" => ([I64], [I64])
    "io/io_result_copy_read/windows" => ([I64, I32, I32, I32], [])
    "io/io_result_copy_read_with_addr/windows" =>
      ([I64, I32, I32, I32, I32, I32], [])
    "io/get_accept_peer_addr/windows" => ([I64, I32, I32], [])
    "io/read/windows"
    | "io/read_dir_changes/windows"
    | "io/write/windows"
    | "io/cancel_io_result/windows"
    | "io/io_result_get_status/windows" => ([I64, I64], [I32])
    "io/free_io_result/windows" => ([I64], [])
    "io/io_result_get_event/windows" => ([I64], [I32])
    "io/errno_is_read_EOF/windows" => ([I32], [I32])
    _ => return None
  }
  Some({ params, results, })
}

///|
fn Context::io_result_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.async_host
  if name == "io/errno_is_read_EOF/windows" {
    let code = i32(args[0])
    return [I32(if code == 109 || code == 38 { 1 } else { 0 })]
  }
  if name.has_prefix("io/make_") {
    let (operation, length, data, position, flags) : (
      @resource.IoOperation,
      Int32,
      Bytes,
      Int64,
      Int32,
    ) = if name == "io/make_read_dir_changes_io_result/windows" {
      guard host.buffers.get(i64(args[0])) is Some(buffer) &&
        buffer.length() == 65536 else {
        raise @vm.TypeMismatch
      }
      (WatchDirectory(buffer), buffer.length(), b"", -1L, 0)
    } else if name == "io/make_connect_io_result/windows" {
      let address = guest_bytes(caller, i32(args[0]), i32(args[1]))
      ignore(@sys.decode_address(address))
      (Connect(address), 0, b"", -1L, 0)
    } else if name == "io/make_accept_io_result/windows" {
      let length = i32(args[0])
      guard length == @sys.ipv4_address_size() ||
        length == @sys.ipv6_address_size() else {
        raise @vm.TypeMismatch
      }
      (Accept(length), 0, b"", -1L, 0)
    } else {
      let reading = name == "io/make_file_read_io_result/windows" ||
        name == "io/make_socket_read_io_result/windows" ||
        name == "io/make_socket_with_addr_read_io_result/windows"
      let length = i32(args[if reading { 0 } else { 2 }])
      guard length >= 0 else { raise @vm.OutOfBoundsMemoryAccess }
      let data = if reading {
        b""
      } else {
        let pointer = i32(args[0]).reinterpret_as_uint().to_int64() +
          i32(args[1]).reinterpret_as_uint().to_int64()
        guard pointer <= 0xFFFF_FFFFL else { raise @vm.OutOfBoundsMemoryAccess }
        guest_bytes(caller, pointer.to_int(), length)
      }
      let file = name.has_prefix("io/make_file_")
      let position = if file {
        i64(args[if reading { 1 } else { 3 }])
      } else {
        -1L
      }
      guard position >= -1L else { raise @vm.TypeMismatch }
      let flags = if file { 0 } else { i32(args[if reading { 1 } else { 3 }]) }
      let operation : @resource.IoOperation = if name.has_prefix(
          "io/make_socket_with_addr_",
        ) {
        let address = guest_bytes(
          caller,
          i32(args[if reading { 2 } else { 4 }]),
          i32(args[if reading { 3 } else { 5 }]),
        )
        ignore(@sys.decode_address(address))
        if reading {
          Receive(address)
        } else {
          Send(address)
        }
      } else if reading {
        Read
      } else {
        Write
      }
      (operation, length, data, position, flags)
    }
    let handle = self.runtime.handles.allocate()
    host.io_results[handle] = {
      operation,
      length,
      data,
      position,
      flags,
      task: None,
      result: None,
      pending: false,
      fd: None,
      peer: None,
    }
    return [I64(handle)]
  }
  let submitting = name == "io/read/windows" ||
    name == "io/write/windows" ||
    name == "io/read_dir_changes/windows"
  let handle = i64(args[if submitting { 1 } else { 0 }])
  guard host.io_results.get(handle) is Some(io) else { raise @vm.TypeMismatch }
  if submitting {
    guard io.operation.event() ==
      (if name == "io/write/windows" { 2 } else { 1 }) else {
      raise @vm.TypeMismatch
    }
    return [
      I32(
        host.start_io(io, handle, i64(args[0]), fd => {
          let position = if fd.owner
            is (Pipe(_, _) | Standard(_, _) | @resource.Socket(_)) {
            -1L
          } else {
            io.position
          }
          match io.operation {
            WatchDirectory(buffer) => {
              guard name == "io/read_dir_changes/windows" &&
                fd.owner is @resource.Watcher(_) else {
                raise @os_error.OSError(
                  87,
                  context="directory change notification",
                )
              }
              let result = @native_jobs.run_native_job(
                ReadWatchEvents,
                "",
                fd.native(),
                0,
                buffer.length(),
                false,
              )
              if result.ret >= 0 {
                result.data
                .to_fixedarray()
                .blit_to(buffer, len=result.data.length())
              }
              result
            }
            Read =>
              self.runtime.stdio.read_fd(
                fd,
                io.length,
                position,
                flags=io.flags,
              )
            Write =>
              self.runtime.stdio.write_fd(fd, io.data, position, flags=io.flags)
            _ => self.runtime.network.perform_socket_io(io, fd)
          }
        }),
      ),
    ]
  }
  match name {
    "io/io_result_get_event/windows" => [I32(io.operation.event())]
    "io/free_io_result/windows" => {
      guard !io.pending else { raise @vm.TypeMismatch }
      host.io_results.remove(handle)
      []
    }
    "io/cancel_io_result/windows" | "io/io_result_get_status/windows" => {
      guard io.fd == Some(i64(args[1])) else {
        host.async_errno = @sys.bad_fd_errno
        return [I32(-1)]
      }
      if name == "io/cancel_io_result/windows" {
        if io.pending {
          if io.task is Some(task) {
            task.cancel()
          }
          [I32(1)]
        } else {
          [I32(0)]
        }
      } else if io.result is Some(result) {
        host.async_errno = result.errno
        [I32(result.ret)]
      } else {
        host.async_errno = 996
        [I32(-1)]
      }
    }
    "io/get_accept_peer_addr/windows" => {
      guard io.result is Some(result) &&
        result.ret >= 0 &&
        io.peer is Some(address) else {
        raise @vm.TypeMismatch
      }
      guard i32(args[2]) >= address.length() else {
        raise @vm.OutOfBoundsMemoryAccess
      }
      guest_memory(caller).init_data_at(
        i32(args[1]).reinterpret_as_uint().to_int64(),
        address,
      )
      []
    }
    "io/io_result_copy_read/windows"
    | "io/io_result_copy_read_with_addr/windows" => {
      guard io.result is Some(result) && result.ret >= 0 else {
        raise @vm.TypeMismatch
      }
      let address = i32(args[1]).reinterpret_as_uint().to_int64() +
        i32(args[2]).reinterpret_as_uint().to_int64()
      let length = i32(args[3])
      let memory = guest_memory(caller)
      guard address <= 0xFFFF_FFFFL &&
        length >= 0 &&
        length <= result.data.length() &&
        address + length.to_int64() <= memory.byte_len() else {
        raise @vm.OutOfBoundsMemoryAccess
      }
      if name == "io/io_result_copy_read_with_addr/windows" {
        guard io.operation is Receive(peer) && i32(args[5]) == peer.length() else {
          raise @vm.TypeMismatch
        }
        let pointer = i32(args[4]).reinterpret_as_uint().to_int64()
        guard pointer + peer.length().to_int64() <= memory.byte_len() else {
          raise @vm.OutOfBoundsMemoryAccess
        }
        memory.init_data_at(pointer, peer)
      }
      memory.init_data_at(address, result.data[:length].to_owned())
      []
    }
    _ => raise @vm.UnknownImport("moonbitlang/async", name)
  }
}
