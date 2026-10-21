///|
pub(all) enum ResourceOperation {
  Stat
  Sync
  Lock
}

///|
pub fn resource_job(
  filesystem : @filesystem.HostFs,
  fd : @resource.Resource,
  operation : ResourceOperation,
  value : Int32,
  capacity : Int32,
) -> @resource.Task raise {
  if operation is Stat {
    filesystem.authorize_resource(fd, false)
    ignore(@native_jobs.stat_length(value, capacity))
    @resource.Task(@sys.fstat_job(fd.native(), value, capacity))
  } else {
    guard fd.owner is File(_) else {
      raise @sys.OSError(@sys.bad_fd_errno, context="file job")
    }
    if operation is Lock && value != 0 {
      filesystem.authorize_resource(fd, true)
    }
    @resource.Task(
      @sys.file_job(if operation is Sync { 14 } else { 15 }, fd.native(), value),
    )
  }
}
