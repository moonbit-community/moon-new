///|
pub async fn stat(
  filesystem : @filesystem.HostFs,
  path : String,
  parent : @resource.Resource?,
  follow : Bool,
  request : Int32,
  capacity : Int32,
) -> @resource.JobResult {
  let capacity = @native_jobs.stat_length(request, capacity)
  filesystem.authorize_at(path, parent, follow)
  @native_jobs.run_native_job(
    StatPath,
    path,
    match parent {
      Some(fd) => fd.native()
      None => @sys.invalid_native_fd()
    },
    request,
    capacity,
    follow,
  )
}
