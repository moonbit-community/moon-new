///|
pub async fn HostNetwork::perform_socket_io(
  self : HostNetwork,
  io : @resource.IoResult,
  fd : @resource.Resource,
) -> @resource.JobResult {
  guard fd.owner is @resource.Socket(socket) else {
    raise @os_error.OSError(@sys.bad_fd_errno, context="socket I/O")
  }
  if io.operation.event() == 1 {
    fd.read_lock.acquire()
  } else {
    fd.write_lock.acquire()
  }
  defer (if io.operation.event() == 1 {
    fd.read_lock.release()
  } else {
    fd.write_lock.release()
  })
  let mut data = b""
  let ret = match io.operation {
    Connect(address) => {
      self.authorize_socket(false, address)
      socket.connect(address)
      0
    }
    Receive(address) => {
      let buffer = FixedArray::make(io.length, b'\x00')
      let count = for ;; {
        let sequence = socket.read_sequence
        let count = @sys.socket_recvfrom(
          socket.fd,
          buffer,
          io.length,
          io.flags,
          address,
          address.length(),
        )
        if count >= 0 {
          break count
        }
        let error = @os_error.OSError(
          @os_error.get_errno(),
          context="socket receive",
        )
        if error.is_EINTR() {
          continue
        }
        if !error.is_nonblocking_io_error() {
          raise error
        }
        socket.wait_read(sequence)
      }
      data = Bytes::from_array(buffer[:count])
      count
    }
    Send(address) => {
      self.authorize_socket(false, address)
      for ;; {
        let sequence = socket.write_sequence
        let count = @sys.socket_sendto(
          socket.fd,
          io.data,
          io.data.length(),
          io.flags,
          address,
          address.length(),
        )
        if count >= 0 {
          break count
        }
        let error = @os_error.OSError(
          @os_error.get_errno(),
          context="socket send",
        )
        if error.is_EINTR() {
          continue
        }
        if !error.is_nonblocking_io_error() {
          raise error
        }
        socket.wait_write(sequence)
      }
    }
    _ => raise @os_error.OSError(87, context="socket I/O operation")
  }
  { ret, errno: 0, data, opened: None, }
}
