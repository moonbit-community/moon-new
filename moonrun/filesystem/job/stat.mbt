///|
pub fn stat(
  filesystem : @filesystem.HostFs,
  path : String,
  parent : @resource.Resource?,
  follow : Bool,
  request : Int32,
  capacity : Int32,
) -> @resource.Task raise {
  let capacity = @native_jobs.stat_length(request, capacity)
  filesystem.authorize_at(path, parent, follow)
  @resource.Task(
    @sys.stat_job(
      path,
      parent.map(fd => fd.native()).unwrap_or_else(@sys.invalid_native_fd),
      request,
      capacity,
      follow,
    ),
  )
}
