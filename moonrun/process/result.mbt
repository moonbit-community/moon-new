///|
/// Return the exit status, consuming Unix child results once. Windows process
/// handles retain their cached result for repeated status queries.
pub fn HostProcess::get_result(
  self : HostProcess,
  handle : Int64,
  pid : Int32,
) -> Int32 raise @sys.OSError {
  if handle == 0L ||
    (handle == self.handles.invalid_fd && @sys.platform is Windows) {
    raise @sys.OSError(@sys.bad_fd_errno, context="process handle")
  }
  let child = if self.policy is None &&
    self.process_handles.get(handle) is Some(Child(child)) {
    Some(child)
  } else {
    self.children.get(pid)
  }
  let child = child.filter(child => {
    !child.consumed ||
    (
      @sys.platform is Windows &&
      self.process_handles.get(handle) is Some(Child(owner)) &&
      owner.identity == child.identity
    )
  })
  if self.policy is None &&
    (self.process_handles.get(handle) is Some(External(_)) || child is None) {
    let fd = match self.process_handles.get(handle) {
      Some(External(process)) => process.fd
      None if handle == self.handles.invalid_fd && !(@sys.platform is Windows) =>
        @sys.invalid_native_fd()
      _ => raise @sys.OSError(@sys.bad_fd_errno, context="process handle")
    }
    return poll_process(fd, pid)
  }
  guard child is Some(child) else {
    raise @sys.OSError(
      if self.policy is Some(_) {
        if @sys.platform is Windows {
          5
        } else {
          13
        }
      } else {
        @sys.bad_fd_errno
      },
      context="process authority",
    )
  }
  if handle != self.handles.invalid_fd &&
    !(self.process_handles.get(handle) is Some(Child(owner)) &&
    owner.identity == child.identity) {
    raise @sys.OSError(@sys.bad_fd_errno, context="process provenance")
  }
  guard child.result is Some(result) else {
    raise @sys.OSError(
      if @sys.platform is Windows {
        997
      } else if @sys.platform is MacOS {
        35
      } else {
        11
      },
      context="process pending",
    )
  }
  if child.error != 0 {
    raise @sys.OSError(child.error, context="child process")
  }
  child.consumed = true
  child.release_if_finished()
  result
}
