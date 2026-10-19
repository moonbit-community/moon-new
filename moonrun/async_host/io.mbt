///|
pub fn AsyncHost::start_io(
  self : AsyncHost,
  io : @resource.IoResult,
  handle : Int64,
  key : Int64,
  action : async (@resource.Resource) -> @resource.JobResult,
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
  io.fd = Some(key)
  io.pending = true
  fd.retain()
  io.task = Some(
    self.group.spawn(no_wait=true, () => {
      defer fd.release()
      let result = @async.handle_cancellation(() => {
        action(fd) catch {
          @os_error.OSError(code, ..) =>
            { ret: -1, errno: code, data: b"", opened: None, }
          error => raise error
        }
      })
      io.result = Some(
        result.unwrap_or_else(() => {
          ret: -1,
          errno: 995,
          data: b"",
          opened: None,
        }),
      )
      if !self.shutting_down && !bus.closed {
        let count = match io.result {
          Some(result) => @cmp.maximum(0, result.ret)
          None => 0
        }
        if @sys.post_completion(bus.native, key, handle, count) < 0 {
          raise @sys.Operation("failed to post I/O completion")
        }
      }
    }),
  )
  self.async_errno = 997
  -1
}
