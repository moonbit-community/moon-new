///|
pub fn wait_external(process : ProcessHandle?, pid : Int32) -> @resource.Task {
  let fd = match process {
    Some(External(process)) => process.fd
    _ => @sys.invalid_native_fd()
  }
  @resource.Task(@sys.wait_child_operation(@sys.null_child(), fd, pid))
}

///|
pub fn Child::wait(self : Child) -> @resource.Task {
  let operation = @sys.wait_child_operation(
    self.native,
    @sys.invalid_native_fd(),
    0,
  )
  @resource.Task(operation, publish=() => {
    let result = @resource.result(operation)
    if self.consumed {
      return { ret: -1, errno: @sys.bad_fd_errno, data: b"", opened: None, }
    }
    if !(@sys.platform is Windows) {
      self.consumed = true
      self.release_if_finished()
    }
    result
  })
}
