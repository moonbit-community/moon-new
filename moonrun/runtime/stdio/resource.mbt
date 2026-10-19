///|
pub async fn Stdio::read_fd(
  self : Stdio,
  fd : @resource.Resource,
  length : Int32,
  position : Int64,
  flags~ : Int32 = 0,
) -> @resource.JobResult {
  if flags != 0 && !(fd.owner is @resource.Socket(_)) {
    raise @os_error.OSError(87, context="I/O flags")
  }
  if fd.owner is Standard(id, _) {
    guard id == 0 else {
      raise @os_error.OSError(
        @sys.bad_fd_errno,
        context="standard stream direction",
      )
    }
    fd.read_lock.acquire()
    defer fd.read_lock.release()
    let data = self.read_chunk(length)
    { ret: data.length(), errno: 0, data, opened: None, }
  } else {
    fd.read_job(length, position, flags~)
  }
}

///|
pub async fn Stdio::write_fd(
  self : Stdio,
  fd : @resource.Resource,
  data : Bytes,
  position : Int64,
  flags~ : Int32 = 0,
) -> @resource.JobResult {
  if flags != 0 && !(fd.owner is @resource.Socket(_)) {
    raise @os_error.OSError(87, context="I/O flags")
  }
  if fd.owner is Standard(id, _) {
    guard id == 1 || id == 2 else {
      raise @os_error.OSError(
        @sys.bad_fd_errno,
        context="standard stream direction",
      )
    }
    fd.write_lock.acquire()
    defer fd.write_lock.release()
    self.output(id, data)
    { ret: data.length(), errno: 0, data: b"", opened: None, }
  } else {
    fd.write_job(data, position, flags~)
  }
}
