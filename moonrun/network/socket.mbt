///|
pub fn HostNetwork::bind(
  self : HostNetwork,
  socket : @resource.Resource,
  address : Bytes,
) -> Unit raise {
  self.authorize_socket(true, address)
  if @sys.bind_socket(socket.native(), address, address.length()) < 0 {
    @sys.check_errno("socket bind")
  }
}

///|
pub fn HostNetwork::connect(
  self : HostNetwork,
  socket : @resource.Resource,
  address : Bytes,
) -> Unit raise {
  self.authorize_socket(false, address)
  if @sys.connect_socket(socket.native(), address, address.length()) < 0 {
    @sys.check_errno("socket connect")
  }
}

///|
pub fn HostNetwork::send_to(
  self : HostNetwork,
  socket : @resource.Resource,
  buffer : Bytes,
  address : Bytes,
) -> Int32 raise {
  self.authorize_socket(false, address)
  let count = @sys.socket_sendto(
    socket.native(),
    buffer,
    buffer.length(),
    0,
    address,
    address.length(),
  )
  if count < 0 {
    @sys.check_errno("socket send")
  }
  count
}

///|
pub fn HostNetwork::bind_job(
  self : HostNetwork,
  socket : @resource.Resource,
  address : Bytes,
) -> @resource.Task raise {
  self.authorize_socket(true, address)
  @resource.Task(@sys.network_job(0, socket.native(), address, b"", 0, 0))
}
