///|
pub fn Stdio::read_fd(
  self : Stdio,
  fd : @resource.Resource,
  length : Int32,
  position : Int64,
  flags~ : Int32 = 0,
) -> @resource.JobResult raise {
  if flags != 0 && !(fd.owner is @resource.Socket(_)) {
    raise @sys.OSError(87, context="I/O flags")
  }
  if fd.owner is Standard(id, _) {
    guard id == 0 else {
      raise @sys.OSError(@sys.bad_fd_errno, context="standard stream direction")
    }
    let data = self.read_chunk(length)
    { ret: data.length(), errno: 0, data, opened: None, }
  } else {
    fd.read_job(length, position, flags~)
  }
}

///|
pub fn Stdio::write_fd(
  self : Stdio,
  fd : @resource.Resource,
  data : Bytes,
  position : Int64,
  flags~ : Int32 = 0,
) -> @resource.JobResult raise {
  if flags != 0 && !(fd.owner is @resource.Socket(_)) {
    raise @sys.OSError(87, context="I/O flags")
  }
  if fd.owner is Standard(id, _) {
    guard id == 1 || id == 2 else {
      raise @sys.OSError(@sys.bad_fd_errno, context="standard stream direction")
    }
    self.output(id, data)
    { ret: data.length(), errno: 0, data: b"", opened: None, }
  } else {
    fd.write_job(data, position, flags~)
  }
}

///|
pub fn Stdio::prepare_read(
  self : Stdio,
  fd : @resource.Resource,
  length : Int32,
  position : Int64,
  flags~ : Int32 = 0,
) -> @resource.Task raise {
  if fd.owner is Standard(id, _) {
    guard id == 0 else {
      raise @sys.OSError(@sys.bad_fd_errno, context="standard input direction")
    }
    if self.stdin is Some(_) || self.input_offset < self.input.length() {
      return @resource.Task::ready(self.read_fd(fd, length, position, flags~))
    }
  }
  fd.prepare_read(length, position, flags~)
}

///|
pub fn Stdio::prepare_write(
  self : Stdio,
  fd : @resource.Resource,
  data : Bytes,
  position : Int64,
  flags~ : Int32 = 0,
) -> @resource.Task raise {
  if fd.owner is Standard(id, _) {
    guard id == 1 || id == 2 else {
      raise @sys.OSError(@sys.bad_fd_errno, context="standard output direction")
    }
    let callback = if id == 2 { self.stderr } else { self.stdout }
    if callback is Some(write) {
      return @resource.Task(@sys.sleep_job(0), publish=() => {
        write(data)
        { ret: data.length(), errno: 0, data: b"", opened: None, }
      })
    }
  }
  fd.prepare_write(data, position, flags~)
}
