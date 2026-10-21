///|
pub(all) enum PathOperation {
  Remove
  RemoveDirectory
  CreateDirectory
  Chmod
  Access
  Realpath
}

///|
pub fn path_job(
  filesystem : @filesystem.HostFs,
  operation : PathOperation,
  path : String,
  value : Int32,
) -> @resource.Task raise {
  let write = !(operation is Realpath) && (!(operation is Access) || value == 2)
  filesystem.authorize_path(
    path,
    read=!write,
    write~,
    entry=operation is Remove ||
      operation is RemoveDirectory ||
      operation is CreateDirectory,
  )
  @resource.Task(
    @sys.path_job(
      match operation {
        Remove => 1
        RemoveDirectory => 2
        CreateDirectory => 3
        Chmod => 4
        Access => 5
        Realpath => 6
      },
      path,
      value~,
    ),
  )
}

///|
pub fn rename_or_symlink(
  filesystem : @filesystem.HostFs,
  rename : Bool,
  first : String,
  second : String,
  flag : Bool,
) -> @resource.Task raise {
  if first.contains_char('\u0000') || second.contains_char('\u0000') {
    raise @sys.OSError(
      if @sys.platform is Windows {
        87
      } else {
        22
      },
      context="path",
    )
  }
  let first = if rename { filesystem.resolve(first) } else { first }
  if rename {
    filesystem.authorize_path(first, read=false, write=true, entry=true)
  }
  filesystem.authorize_path(second, read=false, write=true, entry=true)
  @resource.Task(
    @sys.path_job(if rename { 7 } else { 8 }, first, second~, flag~),
  )
}
