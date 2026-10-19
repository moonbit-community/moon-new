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
pub async fn path_job(
  filesystem : @filesystem.HostFs,
  operation : PathOperation,
  path : String,
  value : Int32,
) -> @resource.JobResult {
  let write = !(operation is Realpath) && (!(operation is Access) || value == 2)
  filesystem.authorize_path(
    path,
    read=!write,
    write~,
    entry=operation is Remove ||
      operation is RemoveDirectory ||
      operation is CreateDirectory,
  )
  let mut data = b""
  let mut ret = 0
  let mut errno = 0
  if path.contains_char('\u0000') {
    raise @os_error.OSError(
      if @async.platform is Windows {
        87
      } else {
        22
      },
      context="path",
    )
  }
  match operation {
    Remove => @fs.remove(path)
    RemoveDirectory => @fs.rmdir(path)
    CreateDirectory => @fs.mkdir(path, permission=value)
    Chmod => @fs.chmod(path, value)
    Realpath => {
      let resolved = @fs.realpath(path)
      data = if @async.platform is Windows {
        @utf16.encode(resolved, endianness=Little, bom=false) + b"\x00\x00"
      } else {
        @utf8.encode(resolved) + b"\x00"
      }
    }
    Access => {
      let allowed = match value {
        0 => @fs.exists(path)
        1 => @fs.can_read(path)
        2 => @fs.can_write(path)
        3 => @fs.can_execute(path)
        _ =>
          raise @os_error.OSError(
            if @async.platform is Windows {
              87
            } else {
              22
            },
            context="access mode",
          )
      }
      if !allowed {
        ret = -1
        errno = if @fs.exists(path) {
          if @async.platform is Windows {
            5
          } else {
            13
          }
        } else {
          2
        }
      }
    }
  }
  { ret, errno, data, opened: None, }
}

///|
pub async fn rename_or_symlink(
  filesystem : @filesystem.HostFs,
  rename : Bool,
  first : String,
  second : String,
  flag : Bool,
) -> @resource.JobResult {
  if first.contains_char('\u0000') || second.contains_char('\u0000') {
    raise @os_error.OSError(
      if @async.platform is Windows {
        87
      } else {
        22
      },
      context="path",
    )
  }
  if rename {
    filesystem.authorize_path(
      filesystem.resolve(first),
      read=false,
      write=true,
      entry=true,
    )
    filesystem.authorize_path(second, read=false, write=true, entry=true)
    @fs.rename(filesystem.resolve(first), second, replace=flag)
  } else {
    filesystem.authorize_path(second, read=false, write=true, entry=true)
    @fs.symlink(target=first, second, force_symlink=flag)
  }
  { ret: 0, errno: 0, data: b"", opened: None, }
}
