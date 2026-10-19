///|
pub(all) enum ResourceOperation {
  Stat
  Sync
  Lock
}

///|
pub async fn resource_job(
  filesystem : @filesystem.HostFs,
  fd : @resource.Resource,
  operation : ResourceOperation,
  value : Int32,
  capacity : Int32,
) -> @resource.JobResult {
  let data = if operation is Stat {
    filesystem.authorize_resource(fd, false)
    @native_jobs.packed_stat(fd.native(), value, capacity)
  } else {
    guard fd.owner is File(file) else {
      raise @os_error.OSError(@sys.bad_fd_errno, context="file job")
    }
    if operation is Sync {
      file.sync(only_data=value != 0)
    } else {
      if value != 0 {
        filesystem.authorize_resource(fd, true)
      }
      file.lock(if value != 0 { Exclusive } else { Shared })
    }
    b""
  }
  { ret: 0, errno: 0, data, opened: None, }
}
