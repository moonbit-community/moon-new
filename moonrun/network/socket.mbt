///|
pub async fn HostNetwork::bind(
  self : HostNetwork,
  socket : @resource.Resource,
  address : Bytes,
) -> Unit {
  self.authorize_socket(true, address)
  if @sys.bind_socket(socket.native(), address, address.length()) < 0 {
    @os_error.check_errno("socket bind")
  }
}

///|
pub async fn HostNetwork::connect(
  self : HostNetwork,
  socket : @resource.Resource,
  address : Bytes,
) -> Unit {
  self.authorize_socket(false, address)
  if @sys.connect_socket(socket.native(), address, address.length()) < 0 {
    @os_error.check_errno("socket connect")
  }
}

///|
pub async fn HostNetwork::send_to(
  self : HostNetwork,
  socket : @resource.Resource,
  buffer : Bytes,
  address : Bytes,
) -> Int32 {
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
    @os_error.check_errno("socket send")
  }
  count
}

///|
pub async fn HostNetwork::bind_job(
  self : HostNetwork,
  socket : @resource.Resource,
  address : Bytes,
) -> @resource.JobResult {
  self.bind(socket, address)
  { ret: 0, errno: 0, data: b"", opened: None, }
}
