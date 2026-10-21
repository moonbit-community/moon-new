///|
pub struct Socket {
  fd : @sys.Fd
  priv mut closed : Bool
}

///|
pub fn Socket::close(self : Socket) -> Unit {
  if !self.closed {
    self.closed = true
    @sys.close_socket(self.fd)
  }
}

///|
pub fn Resource::new_socket(fd : @sys.Fd) -> Resource raise {
  errdefer @sys.close_socket(fd)
  if @sys.prepare_socket(fd) < 0 {
    @sys.check_errno("prepare socket")
  }
  Resource(Socket({ fd, closed: false, }))
}
