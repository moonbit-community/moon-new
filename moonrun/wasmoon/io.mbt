///|
fn Context::pipe_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.async_host
  try {
    if name == "fd_util/invalid_fd" {
      return [I64(self.runtime.handles.invalid_fd)]
    }
    if name == "fd_util/pipe" {
      let memory = guest_memory(caller)
      let address = i32(args[0]).reinterpret_as_uint().to_int64()
      guard i32(args[1]).reinterpret_as_uint() >= 2U &&
        address + 16L <= memory.byte_len() else {
        raise @vm.OutOfBoundsMemoryAccess
      }
      let read_async = i32(args[2]) != 0
      let write_async = i32(args[3]) != 0
      return self.suspend(() => {
        let endpoints = FixedArray::make(2, @sys.invalid_native_fd())
        // Windows guest completions are virtual: native async operates on
        // synchronous HANDLEs through RawFd and forwards their completion.
        if @sys.create_guest_pipe(
            endpoints,
            !(@async.platform is Windows) && read_async,
            !(@async.platform is Windows) && write_async,
          ) <
          0 {
          host.async_errno = @os_error.get_errno()
          return [I32(-1)]
        }
        let adopted = Some(
          @async.protect_from_cancel(() => {
            let read = {
              errdefer ignore(@sys.close_guest_pipe(endpoints[1]))
              @raw_fd.RawFd(endpoints[0])
            }
            errdefer read.close()
            (read, @raw_fd.RawFd(endpoints[1]))
          }),
        ) catch {
          @os_error.OSError(code, ..) => {
            host.async_errno = code
            None
          }
          error => raise error
        }
        guard adopted is Some((read, write)) else { return [I32(-1)] }
        let read_handle = self.runtime.handles.allocate()
        let write_handle = self.runtime.handles.allocate()
        host.fds[read_handle] = @resource.Resource(
          Pipe(read, true),
          guest_async=read_async,
        )
        host.fds[write_handle] = @resource.Resource(
          Pipe(write, false),
          guest_async=write_async,
        )
        memory.store_i64(address.to_int(), read_handle)
        memory.store_i64((address + 8L).to_int(), write_handle)
        [I32(0)]
      })
    }
    let handle = i64(args[0])
    if name == "fd_util/set_cloexec" {
      guard host.fds.get(handle) is Some(fd) else {
        host.async_errno = @sys.bad_fd_errno
        return [I32(-1)]
      }
      return self.socket_status(@sys.fd_cloexec(fd.native()))
    }
    if name == "fd_util/close_fd" {
      if self.runtime.process.close_handle(handle) {
        return [I32(0)]
      }
      guard host.fds.get(handle) is Some(fd) else {
        host.async_errno = @sys.bad_fd_errno
        return [I32(-1)]
      }
      host.fds.remove(handle)
      fd.release()
      return [I32(0)]
    }
    // These imports are immediate syscall attempts. Suspending here would keep
    // the guest scheduler from running its other coroutines before event_bus/wait.
    let memory = guest_memory(caller)
    let offset = i32(args[2]).reinterpret_as_uint().to_int64()
    let length = i32(args[3])
    let address = i32(args[1]).reinterpret_as_uint().to_int64() + offset
    guard address <= 0xFFFF_FFFFL &&
      length >= 0 &&
      address + length.to_int64() <= memory.byte_len() else {
      raise @vm.OutOfBoundsMemoryAccess
    }
    guard host.fds.get(handle) is Some(fd) else {
      host.async_errno = @sys.bad_fd_errno
      return [I32(-1)]
    }
    if !fd.guest_async || fd.owner is Standard(_, _) {
      let writing = name == "io/write/unix"
      let data = if writing {
        memory.read_bytes(address.to_int(), length)
      } else {
        b""
      }
      return self.suspend(() => {
        try {
          let result = if writing {
            self.runtime.stdio.write_fd(fd, data, -1L)
          } else {
            self.runtime.stdio.read_fd(fd, length, -1L)
          }
          if !writing {
            memory.init_data_at(address, result.data)
          }
          [I32(result.ret)]
        } catch {
          @os_error.OSError(code, ..) => {
            host.async_errno = code
            [I32(-1)]
          }
          error => raise error
        }
      })
    }
    let buffer = if name == "io/write/unix" {
      memory.read_bytes(address.to_int(), length).to_fixedarray()
    } else {
      FixedArray::make(length, b'\x00')
    }
    let count = if name == "io/write/unix" {
      if fd.owner is @resource.Socket(_) {
        @sys.socket_write(fd.native(), Bytes::from_array(buffer), length, 0)
      } else {
        @sys.write_guest_pipe(fd.native(), buffer, length)
      }
    } else {
      @sys.read_guest_pipe(fd.native(), buffer, length)
    }
    if count < 0 {
      host.async_errno = @os_error.get_errno()
    } else if name == "io/read/unix" {
      memory.init_data_at(address, Bytes::from_array(buffer[:count]))
    }
    [I32(count)]
  } catch {
    @vm.OutOfBoundsMemoryAccess | @sys.Bounds => {
      host.async_errno = @sys.fault_errno
      [I32(-1)]
    }
    error => raise error
  }
}
