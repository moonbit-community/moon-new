///|
pub async fn open(
  filesystem : @filesystem.HostFs,
  path : String,
  access : Int32,
  create : Int32,
  append : Bool,
  sync : Int32,
  permission : Int32,
  request : Int32,
  capacity : Int32,
) -> @resource.JobResult {
  let invalid = if @async.platform is Windows { 87 } else { 22 }
  filesystem.authorize_path(
    path,
    read=access is (0 | 2 | 3),
    write=access is (1 | 2) || create != 0 || append,
  )
  if (request & -14) != 0 {
    filesystem.authorize_path(path)
  }
  if path.contains_char('\u0000') {
    raise @os_error.OSError(invalid, context="open path")
  }
  if access == 3 && @async.platform is Windows {
    let result = @native_jobs.run_native_job(
      OpenWatcher,
      path,
      @sys.invalid_native_fd(),
      0,
      0,
      false,
    )
    if result.ret < 0 {
      raise @os_error.OSError(result.errno, context="open directory watcher")
    }
    guard result.opened is Some(fd) else { raise @sys.Invalid }
    errdefer fd.release()
    fd.path = Some(@fs.realpath(path))
    let data = @native_jobs.packed_stat(fd.native(), request, capacity)
    return { ret: 0, errno: 0, data, opened: Some(fd), }
  }
  let mode : @fs.Mode = match access {
    0 => ReadOnly
    1 => WriteOnly
    2 => ReadWrite
    _ => raise @os_error.OSError(invalid, context="open access")
  }
  let create_mode : @fs.CreateMode = match create {
    0 => OpenExisting
    1 => TruncateExisting
    2 => OpenOrCreate
    3 => CreateOrTruncate
    4 => CreateNew
    _ => raise @os_error.OSError(invalid, context="open create mode")
  }
  let sync : @fs.SyncMode = match sync {
    0 => NoSync
    1 => Data
    2 => Full
    _ => raise @os_error.OSError(invalid, context="open sync mode")
  }
  let file = @fs.open(path, mode~, create_mode~, append~, sync~, permission~)
  errdefer file.close()
  let stat = @native_jobs.packed_stat(file.fd(), request, capacity)
  {
    ret: 0,
    errno: 0,
    data: stat,
    opened: Some(
      @resource.Resource(
        File(file),
        append~,
        path=if filesystem.policy is Some(_) {
          @fs.realpath(path)
        } else {
          path
        },
      ),
    ),
  }
}
