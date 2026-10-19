///|
pub async fn wait_external(
  process : ProcessHandle?,
  pid : Int32,
) -> @resource.JobResult {
  let fd = match process {
    Some(External(process)) => process.fd
    _ => @sys.invalid_native_fd()
  }
  for ;; {
    let result = Some(poll_process(fd, pid)) catch {
      @os_error.OSError(code, ..) if code is (11 | 35 | 997) => None
      error => raise error
    }
    if result is Some(status) {
      return { ret: status, errno: 0, data: b"", opened: None, }
    }
    @async.sleep(1)
  }
}

///|
pub async fn Child::wait(self : Child) -> @resource.JobResult {
  while self.result is None {
    @async.sleep(1)
  }
  if self.consumed {
    return { ret: -1, errno: @sys.bad_fd_errno, data: b"", opened: None, }
  }
  if !(@async.platform is Windows) {
    self.consumed = true
    self.release_if_finished()
  }
  { ret: self.result.unwrap(), errno: self.error, data: b"", opened: None, }
}
