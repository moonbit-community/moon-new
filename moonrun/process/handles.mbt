///|
pub fn HostProcess::publish_child(
  self : HostProcess,
  child : Child,
) -> Int64 raise @os_error.OSError {
  if child.closed {
    raise @os_error.OSError(@sys.bad_fd_errno, context="closed child")
  }
  if @async.platform is MacOS {
    return self.handles.invalid_fd
  }
  let handle = self.handles.allocate()
  self.process_handles[handle] = ProcessHandle::Child(child)
  child.handles += 1
  handle
}

///|
pub fn HostProcess::open_pid_handle(
  self : HostProcess,
  pid : Int32,
) -> Int64 raise @os_error.OSError {
  if self.children.get(pid) is Some(child) && !child.consumed {
    return self.publish_child(child)
  }
  if self.policy is Some(_) {
    raise @os_error.OSError(
      if @async.platform is Windows {
        5
      } else {
        13
      },
      context="process authority",
    )
  }
  if @async.platform is MacOS {
    return self.handles.invalid_fd
  }
  let native = @sys.open_native_process(pid)
  if !@sys.native_process_fd_valid(native) {
    raise @os_error.OSError(@os_error.get_errno(), context="process handle")
  }
  let handle = self.handles.allocate()
  self.process_handles[handle] = External({ fd: native, references: 1, })
  handle
}

///|
pub fn HostProcess::close_handle(self : HostProcess, handle : Int64) -> Bool {
  guard self.process_handles.get(handle) is Some(process) else { return false }
  self.process_handles.remove(handle)
  match process {
    Child(child) => {
      child.handles -= 1
      child.release_if_finished()
    }
    External(process) => process.release()
  }
  true
}
