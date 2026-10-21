///|
pub fn open(
  filesystem : @filesystem.HostFs,
  path : String,
  access : Int32,
  create : Int32,
  append : Bool,
  sync : Int32,
  permission : Int32,
  request : Int32,
  capacity : Int32,
) -> @resource.Task raise {
  filesystem.authorize_path(
    path,
    read=access is (0 | 2 | 3),
    write=access is (1 | 2) || create != 0 || append,
  )
  if (request & -14) != 0 {
    filesystem.authorize_path(path)
  }
  ignore(@native_jobs.stat_length(request, capacity))
  guard access >= 0 &&
    access <= 3 &&
    create >= 0 &&
    create <= 4 &&
    sync >= 0 &&
    sync <= 2 else {
    raise @sys.OSError(
      if @sys.platform is Windows {
        87
      } else {
        22
      },
      context="open options",
    )
  }
  let operation = @sys.open_job(
    path, access, create, append, sync, permission, request, capacity,
  )
  @resource.Task(operation, publish=() => {
    let result = @resource.result(operation)
    if result.ret >= 0 {
      let fd = operation.take_fd()
      let resource = if access == 3 && @sys.platform is Windows {
        @resource.Resource(Watcher({ fd, files: Map([]), }))
      } else {
        @resource.Resource(File(@sys.File::adopt(fd)), append~, path~)
      }
      result.opened = Some(resource)
    }
    result
  })
}
