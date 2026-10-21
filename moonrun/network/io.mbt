///|
pub fn HostNetwork::perform_socket_io(
  self : HostNetwork,
  io : @resource.IoResult,
  fd : @resource.Resource,
) -> @resource.Task raise {
  guard fd.owner is @resource.Socket(_) else {
    raise @sys.OSError(@sys.bad_fd_errno, context="socket I/O")
  }
  let (kind, address) = match io.operation {
    Connect(address) => {
      self.authorize_socket(false, address)
      (1, address)
    }
    Send(address) => {
      self.authorize_socket(false, address)
      (2, address)
    }
    Receive(address) => (3, address)
    _ => raise @sys.OSError(87, context="socket I/O operation")
  }
  let operation = @sys.network_job(
    kind,
    fd.native(),
    address,
    io.data,
    io.length,
    io.flags,
  )
  @resource.Task(operation, publish=() => {
    if io.operation is Receive(_) {
      io.peer = Some(operation.peer())
    }
    @resource.result(operation)
  })
}
