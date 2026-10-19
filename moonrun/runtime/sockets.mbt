///|
extern "C" fn socket_invalid(fd : @types.Fd) -> Bool = "moonrun_socket_invalid"

///|
extern "C" fn prepare_socket(fd : @types.Fd) -> Int32 = "moonrun_socket_prepare"

///|
extern "C" fn close_socket(fd : @types.Fd) -> Unit = "moonrun_socket_close"

///|
extern "C" fn watch_socket(bus : NativeEventBus, fd : @types.Fd) -> Int32 = "moonrun_event_bus_watch_socket"

///|
#borrow(addr)
extern "C" fn bind_socket(
  fd : @types.Fd,
  addr : Bytes,
  length : Int32,
) -> Int32 = "moonrun_socket_bind"

///|
#borrow(addr)
extern "C" fn connect_socket(
  fd : @types.Fd,
  addr : Bytes,
  length : Int32,
) -> Int32 = "moonrun_socket_connect"

///|
#borrow(addr)
extern "C" fn accept_socket(
  fd : @types.Fd,
  addr : Bytes,
  length : Int32,
) -> @types.Fd = "moonrun_socket_accept"

///|
extern "C" fn socket_error(fd : @types.Fd) -> Int32 = "moonrun_socket_error"

///|
#borrow(buffer)
extern "C" fn socket_read(
  fd : @types.Fd,
  buffer : FixedArray[Byte],
  length : Int32,
  flags : Int32,
) -> Int32 = "moonrun_socket_read"

///|
#borrow(buffer)
extern "C" fn socket_write(
  fd : @types.Fd,
  buffer : Bytes,
  length : Int32,
  flags : Int32,
) -> Int32 = "moonrun_socket_write"

///|
priv struct GuestSocket {
  fd : @types.Fd
  read : @cond_var.Cond
  write : @cond_var.Cond
  mut read_sequence : Int64
  mut write_sequence : Int64
  mut pump : @async.Task[Unit]?
  mut closed : Bool
  mut connect_error : Int32?
}

///|
fn GuestSocket::close(self : GuestSocket) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  if self.pump is Some(pump) {
    pump.cancel()
  }
}

///|
fn Host::new_socket(self : Host, fd : @types.Fd) -> GuestFd raise {
  errdefer close_socket(fd)
  if prepare_socket(fd) < 0 {
    @os_error.check_errno("prepare socket")
  }
  let ready = GuestEventBus::new()
  errdefer ready.close()
  let registered = if @async.platform is Windows {
    watch_socket(ready.native, fd)
  } else {
    register_event_fd(ready.native, fd, false, 1L)
  }
  if registered < 1 {
    @os_error.check_errno("watch socket readiness")
  }
  let socket = {
    fd,
    read: @cond_var.Cond(),
    write: @cond_var.Cond(),
    read_sequence: 0L,
    write_sequence: 0L,
    pump: None,
    closed: false,
    connect_error: None,
  }
  socket.pump = Some(
    self.group.spawn(no_wait=true, () => {
      // async guarantees that even an immediately cancelled task executes its
      // body, so these defers also cover cancellation before the pump starts.
      defer {
        socket.closed = true
        ready.close()
        close_socket(fd)
      }
      while !socket.closed {
        let count = ready.wait(-1)
        if count < 0 {
          raise @os_error.OSError(
            event_wait_errno(ready.native),
            context="socket readiness",
          )
        }
        let error = event_wait_errno(ready.native)
        if error > 0 {
          socket.connect_error = Some(error)
        }
        for index in 0..<count {
          let flags = event_flags(ready.native, index)
          if (flags & 1) != 0 {
            socket.read_sequence += 1L
            socket.read.broadcast()
          }
          if (flags & 2) != 0 {
            socket.write_sequence += 1L
            socket.write.broadcast()
          }
        }
      }
    }),
  )
  GuestFd(Socket(socket))
}

///|
async fn GuestSocket::wait_read(self : GuestSocket, sequence : Int64) -> Unit {
  while !self.closed && self.read_sequence == sequence {
    self.read.wait()
  }
  if self.closed {
    raise @os_error.OSError(bad_fd_errno, context="closed socket")
  }
}

///|
async fn GuestSocket::wait_write(self : GuestSocket, sequence : Int64) -> Unit {
  while !self.closed && self.write_sequence == sequence {
    self.write.wait()
  }
  if self.closed {
    raise @os_error.OSError(bad_fd_errno, context="closed socket")
  }
}

///|
async fn GuestSocket::read(
  self : GuestSocket,
  buffer : FixedArray[Byte],
  flags : Int32,
) -> Int32 {
  for ;; {
    let sequence = self.read_sequence
    let count = socket_read(self.fd, buffer, buffer.length(), flags)
    if count >= 0 {
      return count
    }
    let code = @os_error.get_errno()
    let error = @os_error.OSError(code, context="socket read")
    if error.is_EINTR() {
      continue
    }
    if error.is_nonblocking_io_error() {
      self.wait_read(sequence)
    } else {
      raise error
    }
  }
}

///|
async fn GuestSocket::write(
  self : GuestSocket,
  data : Bytes,
  flags : Int32,
) -> Int32 {
  for ;; {
    let sequence = self.write_sequence
    let count = socket_write(self.fd, data, data.length(), flags)
    if count >= 0 {
      return count
    }
    let code = @os_error.get_errno()
    let error = @os_error.OSError(code, context="socket write")
    if error.is_EINTR() {
      continue
    }
    if error.is_nonblocking_io_error() {
      self.wait_write(sequence)
    } else {
      raise error
    }
  }
}
