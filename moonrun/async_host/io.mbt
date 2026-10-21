///|
pub fn AsyncHost::start_io(
  self : AsyncHost,
  io : @resource.IoResult,
  handle : Int64,
  key : Int64,
  action : (@resource.Resource) -> @resource.Task raise,
) -> Int32 raise {
  guard !io.pending && io.result is None else { raise @sys.Invalid }
  guard self.fds.get(key) is Some(fd) else {
    self.async_errno = @sys.bad_fd_errno
    return -1
  }
  let buses = self.buses
    .values()
    .filter(bus => !bus.closed && bus.registered.contains(key))
    .to_array()
  guard buses is [bus] else {
    self.async_errno = 87
    return -1
  }
  let work = action(fd) catch {
    @sys.OSError(code, ..) => {
      self.async_errno = code
      return -1
    }
    error => raise error
  }
  fd.retain()
  io.resource = Some(fd)
  io.fd = Some(key)
  io.pending = true
  io.work = Some(work)
  io.task = Some(
    @sys.start_worker(
      work.operation.raw(),
      0,
      @sys.invalid_native_fd(),
      bus.native,
      key,
      handle,
    ),
  )
  self.async_errno = 997
  -1
}
