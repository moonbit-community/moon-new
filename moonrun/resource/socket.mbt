///|
pub struct Socket {
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
pub fn Socket::close(self : Socket) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  if self.pump is Some(pump) {
    pump.cancel()
  }
}

///|
pub fn Resource::new_socket(
  fd : @types.Fd,
  group : @async.TaskGroup[@termination.RunOutcome],
) -> Resource raise {
  errdefer @sys.close_socket(fd)
  if @sys.prepare_socket(fd) < 0 {
    @os_error.check_errno("prepare socket")
  }
  let ready = @sys.EventBus::new()
  errdefer ready.close()
  let registered = if @async.platform is Windows {
    @sys.watch_socket(ready.native, fd)
  } else {
    @sys.register_event_fd(ready.native, fd, false, 1L)
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
    group.spawn(no_wait=true, () => {
      // async guarantees that even an immediately cancelled task executes its
      // body, so these defers also cover cancellation before the pump starts.
      defer {
        socket.closed = true
        ready.close()
        @sys.close_socket(fd)
      }
      while !socket.closed {
        let count = ready.wait(-1)
        if count < 0 {
          raise @os_error.OSError(
            @sys.event_wait_errno(ready.native),
            context="socket readiness",
          )
        }
        let error = @sys.event_wait_errno(ready.native)
        if error > 0 {
          socket.connect_error = Some(error)
        }
        for index in 0..<count {
          let flags = @sys.event_flags(ready.native, index)
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
  Resource(Socket(socket))
}

///|
pub async fn Socket::wait_read(self : Socket, sequence : Int64) -> Unit {
  while !self.closed && self.read_sequence == sequence {
    self.read.wait()
  }
  if self.closed {
    raise @os_error.OSError(@sys.bad_fd_errno, context="closed socket")
  }
}

///|
pub async fn Socket::wait_write(self : Socket, sequence : Int64) -> Unit {
  while !self.closed && self.write_sequence == sequence {
    self.write.wait()
  }
  if self.closed {
    raise @os_error.OSError(@sys.bad_fd_errno, context="closed socket")
  }
}

///|
pub async fn Socket::read(
  self : Socket,
  buffer : FixedArray[Byte],
  flags : Int32,
) -> Int32 {
  for ;; {
    let sequence = self.read_sequence
    let count = @sys.socket_read(self.fd, buffer, buffer.length(), flags)
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
pub async fn Socket::write(self : Socket, data : Bytes, flags : Int32) -> Int32 {
  for ;; {
    let sequence = self.write_sequence
    let count = @sys.socket_write(self.fd, data, data.length(), flags)
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

///|
pub async fn Socket::connect(self : Socket, address : Bytes) -> Unit {
  self.connect_error = None
  let sequence = self.write_sequence
  if @sys.connect_socket(self.fd, address, address.length()) < 0 {
    let error = @os_error.OSError(
      @os_error.get_errno(),
      context="socket connect",
    )
    if !error.is_nonblocking_io_error() {
      raise error
    }
    self.wait_write(sequence)
    if self.connect_error is Some(error) {
      raise @os_error.OSError(error, context="socket connect")
    }
    let error = @sys.socket_error(self.fd)
    if error < 0 {
      @os_error.check_errno("socket connect status")
    }
    if error > 0 {
      raise @os_error.OSError(error, context="socket connect")
    }
  }
}
