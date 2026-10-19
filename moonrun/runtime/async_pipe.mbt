///|
// POSIX EBADF/EFAULT and Win32 ERROR_INVALID_HANDLE/ERROR_INVALID_ADDRESS.
let bad_fd_errno : Int32 = if @async.platform is Windows { 6 } else { 9 }

///|
let fault_errno : Int32 = if @async.platform is Windows { 487 } else { 14 }

///|
extern "C" fn invalid_native_fd() -> @types.Fd = "moonrun_invalid_fd"

///|
#borrow(endpoints)
extern "C" fn create_guest_pipe(
  endpoints : FixedArray[@types.Fd],
  read_async : Bool,
  write_async : Bool,
) -> Int32 = "moonrun_create_pipe"

///|
extern "C" fn close_guest_pipe(fd : @types.Fd) -> Int32 = "moonrun_close_pipe"

///|
extern "C" fn fd_cloexec(fd : @types.Fd) -> Int32 = "moonrun_fd_cloexec"

///|
#borrow(buffer)
extern "C" fn read_guest_pipe(
  fd : @types.Fd,
  buffer : FixedArray[Byte],
  length : Int32,
) -> Int32 = "moonrun_pipe_read"

///|
#borrow(buffer)
extern "C" fn write_guest_pipe(
  fd : @types.Fd,
  buffer : FixedArray[Byte],
  length : Int32,
) -> Int32 = "moonrun_pipe_write"

///|
fn Host::pipe_import(
  self : Host,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  try {
    if name == "fd_util/invalid_fd" {
      return [I64(0L)]
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
        let endpoints = FixedArray::make(2, invalid_native_fd())
        // Windows guest completions are virtual: native async operates on
        // synchronous HANDLEs through RawFd and forwards their completion.
        if create_guest_pipe(
            endpoints,
            !(@async.platform is Windows) && read_async,
            !(@async.platform is Windows) && write_async,
          ) <
          0 {
          self.async_errno = @os_error.get_errno()
          return [I32(-1)]
        }
        let adopted = Some(
          @async.protect_from_cancel(() => {
            let read = {
              errdefer ignore(close_guest_pipe(endpoints[1]))
              @raw_fd.RawFd(endpoints[0])
            }
            errdefer read.close()
            (read, @raw_fd.RawFd(endpoints[1]))
          }),
        ) catch {
          @os_error.OSError(code, ..) => {
            self.async_errno = code
            None
          }
          error => raise error
        }
        guard adopted is Some((read, write)) else { return [I32(-1)] }
        let read_handle = self.next_handle
        self.next_handle += 2L
        self.fds[read_handle] = GuestFd(
          Pipe(read, true),
          guest_async=read_async,
        )
        self.fds[read_handle + 1L] = GuestFd(
          Pipe(write, false),
          guest_async=write_async,
        )
        memory.store_i64(address.to_int(), read_handle)
        memory.store_i64((address + 8L).to_int(), read_handle + 1L)
        [I32(0)]
      })
    }
    let handle = i64(args[0])
    if name == "fd_util/set_cloexec" {
      guard self.fds.get(handle) is Some(fd) else {
        self.async_errno = bad_fd_errno
        return [I32(-1)]
      }
      return self.socket_status(fd_cloexec(fd.native()))
    }
    if name == "fd_util/close_fd" {
      if self.process_handles.get(handle) is Some(process) {
        self.process_handles.remove(handle)
        match process {
          Child(child) => {
            child.handles -= 1
            child.release_if_finished()
          }
          External(process) => process.release()
        }
        return [I32(0)]
      }
      guard self.fds.get(handle) is Some(fd) else {
        self.async_errno = bad_fd_errno
        return [I32(-1)]
      }
      self.fds.remove(handle)
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
    guard self.fds.get(handle) is Some(fd) else {
      self.async_errno = bad_fd_errno
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
            self.write_fd(fd, data, -1L)
          } else {
            self.read_fd(fd, length, -1L)
          }
          if !writing {
            memory.init_data_at(address, result.data)
          }
          [I32(result.ret)]
        } catch {
          @os_error.OSError(code, ..) => {
            self.async_errno = code
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
      if fd.owner is Socket(_) {
        socket_write(fd.native(), Bytes::from_array(buffer), length, 0)
      } else {
        write_guest_pipe(fd.native(), buffer, length)
      }
    } else {
      read_guest_pipe(fd.native(), buffer, length)
    }
    if count < 0 {
      self.async_errno = @os_error.get_errno()
    } else if name == "io/read/unix" {
      memory.init_data_at(address, Bytes::from_array(buffer[:count]))
    }
    [I32(count)]
  } catch {
    @vm.OutOfBoundsMemoryAccess => {
      self.async_errno = fault_errno
      [I32(-1)]
    }
    error => raise error
  }
}
