///|
pub(all) enum Mode {
  ReadOnly
  WriteOnly
  ReadWrite
}

///|
pub(all) enum CreateMode {
  OpenExisting
  TruncateExisting
  OpenOrCreate
  CreateOrTruncate
  CreateNew
}

///|
pub(all) enum SyncMode {
  NoSync
  Data
  Full
}

///|
pub(all) enum Kind {
  Unknown
  Regular
  Directory
  SymLink
  Block
  Character
  Fifo
  Socket
}

///|
fn Mode::to_int(self : Mode) -> Int32 = "%identity"

///|
fn CreateMode::to_int(self : CreateMode) -> Int32 = "%identity"

///|
fn SyncMode::to_int(self : SyncMode) -> Int32 = "%identity"

///|
pub struct File {
  priv descriptor : Fd
  priv lock : FileLock
  priv mut closed : Bool
}

///|
pub fn File::adopt(fd : Fd) -> File {
  { descriptor: fd, lock: new_file_lock(fd), closed: false, }
}

///|
pub fn File::fd(self : File) -> Fd {
  self.descriptor
}

///|
pub extern "C" fn close_fd(fd : Fd) -> Int32 = "moonrun_close_pipe"

///|
pub extern "C" fn invalid_fd() -> Fd = "moonrun_invalid_fd"

///|
fn checked(operation : Operation, context : String) -> Bytes raise OSError {
  defer operation.close()
  operation.run()
  if operation.ret() < 0 {
    raise OSError(operation.error(), context~)
  }
  operation.buffer()
}

///|
pub fn File::close(self : File) -> Unit {
  if !self.closed {
    self.closed = true
    ignore(close_fd(self.descriptor))
    free_file_lock(self.lock)
  }
}

///|
pub fn open(
  path : String,
  mode~ : Mode,
  create_mode~ : CreateMode = OpenExisting,
  append~ : Bool = false,
  sync~ : SyncMode = NoSync,
  permission~ : Int32 = 0o644,
) -> File raise {
  let operation = open_job(
    path,
    mode.to_int(),
    create_mode.to_int(),
    append,
    sync.to_int(),
    permission,
    0,
    8,
  )
  defer operation.close()
  operation.run()
  if operation.ret() < 0 {
    raise OSError(operation.error(), context="open")
  }
  File::adopt(operation.take_fd())
}

///|
pub fn realpath(path : String) -> String raise {
  let bytes = checked(path_job(6, path), "realpath")
  if platform is Windows {
    @utf16.decode_lossy(bytes[:bytes.length() - 2], endianness=Little)
  } else {
    @utf8.decode_lossy(bytes[:bytes.length() - 1])
  }
}

///|
pub fn kind(path : String, follow_symlink~ : Bool = true) -> Kind raise {
  let bytes = checked(
    stat_job(path, invalid_fd(), 1, 16, follow_symlink),
    "stat",
  )
  match bytes[8].to_int() {
    1 => Regular
    2 => Directory
    3 => SymLink
    4 => Socket
    5 => Fifo
    6 => Block
    7 => Character
    _ => Unknown
  }
}

///|
pub fn exists(path : String) -> Bool raise {
  let operation = path_job(5, path, value=0)
  defer operation.close()
  operation.run()
  operation.ret() >= 0
}

///|
pub fn remove(path : String) -> Unit raise {
  ignore(checked(path_job(1, path), "remove"))
}

///|
pub fn chmod(path : String, mode : Int32) -> Unit raise {
  ignore(checked(path_job(4, path, value=mode), "chmod"))
}

///|
pub fn rename(
  first : String,
  second : String,
  replace~ : Bool = true,
) -> Unit raise {
  ignore(checked(path_job(7, first, second~, flag=replace), "rename"))
}

///|
pub fn symlink(
  target~ : String,
  path : String,
  force_symlink~ : Bool = false,
) -> Unit raise {
  ignore(
    checked(path_job(8, target, second=path, flag=force_symlink), "symlink"),
  )
}

///|
pub fn mkdir(
  path : String,
  recursive~ : Bool = false,
  allow_exist~ : Bool = false,
  permission~ : Int32 = 0o777,
) -> Unit raise {
  if recursive {
    let trimmed = path
      .trim_end(chars=if platform is Windows { "/\\" } else { "/" })
      .to_owned()
    let split = if platform is Windows {
      let slash = trimmed.rev_find("/").unwrap_or(-1)
      let backslash = trimmed.rev_find("\\").unwrap_or(-1)
      let index = @cmp.maximum(slash, backslash)
      if index < 0 {
        None
      } else {
        Some(index)
      }
    } else {
      trimmed.rev_find("/")
    }
    if split is Some(index) && index > 0 && !exists(trimmed[:index].to_owned()) {
      mkdir(
        trimmed[:index].to_owned(),
        recursive=true,
        allow_exist=true,
        permission~,
      )
    }
  }
  ignore(checked(path_job(3, path, value=permission), "mkdir")) catch {
    _ if allow_exist &&
      (try (kind(path) is Directory) catch {
        _ => false
      }) => ()
    error => raise error
  }
}

///|
pub fn File::read(
  self : File,
  buffer : FixedArray[Byte],
  max_len~ : Int32 = buffer.length(),
) -> Int32 raise {
  let data = checked(self.prepare_read(max_len, -1L), "read")
  data.to_fixedarray().blit_to(buffer, len=data.length())
  data.length()
}

///|
pub fn File::write_once(
  self : File,
  data : Bytes,
  offset~ : Int32 = 0,
  len~ : Int32 = data.length() - offset,
) -> Int32 raise {
  let operation = self.prepare_write(data[offset:offset + len].to_owned(), -1L)
  defer operation.close()
  operation.run()
  if operation.ret() < 0 {
    raise OSError(operation.error(), context="write")
  }
  operation.ret()
}

///|
pub(all) enum Lock {
  Shared
  Exclusive
}

///|
pub fn read_file(path : String) -> Bytes raise {
  let file = open(path, mode=ReadOnly)
  defer file.close()
  let buffer = FixedArray::make(65536, b'\x00')
  let output = @buffer.Buffer()
  for ;; {
    let count = file.read(buffer)
    if count == 0 {
      break
    }
    output.write_bytes(Bytes::from_array(buffer[:count]))
  }
  output.to_bytes()
}

///|
pub fn[T : BytesLike] write_file(path : String, value : T) -> Unit raise {
  let data = value.bytes()
  let file = open(path, mode=WriteOnly, create_mode=CreateOrTruncate)
  defer file.close()
  let mut offset = 0
  while offset < data.length() {
    let count = file.write_once(data, offset~)
    if count <= 0 {
      raise OSError(5, context="write file")
    }
    offset += count
  }
}

///|
pub fn readdir(path : String) -> Array[String] raise {
  let code = Ref(0)
  let data = listdir(os_path(path), code)
  if code.val != 0 {
    raise OSError(code.val, context="readdir")
  }
  let text = if platform is Windows {
    @utf16.decode_lossy(data, endianness=Little)
  } else {
    @utf8.decode_lossy(data)
  }
  text
  .split("\u0000")
  .filter(name => !name.is_empty())
  .map(name => name.to_owned())
  .collect()
}

///|
#borrow(path, code)
extern "C" fn listdir(path : Bytes, code : Ref[Int32]) -> Bytes = "moonrun_native_listdir"

///|
pub fn rmdir(path : String, recursive~ : Bool = false) -> Unit raise {
  if recursive {
    for name in readdir(path) {
      let child = path + "/" + name
      if kind(child, follow_symlink=false) is Directory {
        rmdir(child, recursive=true)
      } else {
        remove(child)
      }
    }
  }
  ignore(checked(path_job(2, path), "rmdir"))
}

///|
pub fn can_read(path : String) -> Bool raise {
  can_access(path, 1)
}

///|
pub fn can_write(path : String) -> Bool raise {
  can_access(path, 2)
}

///|
pub fn can_execute(path : String) -> Bool raise {
  can_access(path, 3)
}

///|
fn can_access(path : String, value : Int32) -> Bool raise {
  let operation = path_job(5, path, value~)
  defer operation.close()
  operation.run()
  operation.ret() >= 0
}

///|
extern "C" fn try_lock_file(fd : Fd, exclusive : Bool) -> Int32 = "moonrun_native_try_lock_file"

///|
extern "C" fn unlock_file(fd : Fd) -> Int32 = "moonrun_native_unlock_file"

///|
extern "C" fn lock_violation(code : Int32) -> Bool = "moonrun_native_errno_is_lock_violation"

///|
pub fn File::try_lock(self : File, mode : Lock) -> Bool raise {
  if try_lock_file(self.fd(), mode is Exclusive) >= 0 {
    return true
  }
  let code = get_errno()
  if lock_violation(code) {
    return false
  }
  raise OSError(code, context="try lock")
}

///|
pub fn File::unlock(self : File) -> Unit raise {
  if unlock_file(self.fd()) < 0 {
    check_errno("unlock")
  }
}

///|
let temporary_sequence : Ref[Int32] = Ref(0)

///|
pub fn tmpdir(prefix~ : String = "moonrun-") -> String raise {
  let bytes = copy_tmp_path(native_tmp_path())
  let root = if platform is Windows {
    @utf16.decode_lossy(bytes, endianness=Little)
  } else {
    @utf8.decode_lossy(bytes)
  }
  for ;; {
    temporary_sequence.val += 1
    let path = root +
      (if root.has_suffix("/") || root.has_suffix("\\") { "" } else { "/" }) +
      prefix +
      "\{native_pid()}-\{now()}-\{temporary_sequence.val}"
    mkdir(path) catch {
      OSError(_, ..) as error if error.is_EEXIST() => continue
      error => raise error
    }
    return path
  }
}

///|
pub fn read_file_to_string(path : String) -> String raise {
  @utf8.decode(read_file(path))
}

///|
#external
priv type FileLock

///|
extern "C" fn new_file_lock(fd : Fd) -> FileLock = "moonrun_file_lock_create"

///|
extern "C" fn free_file_lock(lock : FileLock) -> Unit = "moonrun_file_lock_free"

///|
extern "C" fn attach_file_lock(operation : Operation, lock : FileLock) -> Unit = "moonrun_operation_file_lock"

///|
pub fn File::prepare_read(
  self : File,
  length : Int32,
  position : Int64,
) -> Operation raise OSError {
  guard !self.closed else {
    raise OSError(bad_fd_errno, context="read closed file")
  }
  let operation = read_job(self.fd(), length, position)
  attach_file_lock(operation, self.lock)
  operation
}

///|
pub fn File::prepare_write(
  self : File,
  data : Bytes,
  position : Int64,
) -> Operation raise OSError {
  guard !self.closed else {
    raise OSError(bad_fd_errno, context="write closed file")
  }
  let operation = write_job(self.fd(), data, position)
  attach_file_lock(operation, self.lock)
  operation
}

///|
extern "C" fn attach_directory_lock(
  operation : Operation,
  lock : FileLock,
) -> Unit = "moonrun_operation_directory_lock"

///|
pub fn File::prepare_directory(
  self : File,
  capacity : Int32,
  restart : Bool,
) -> Operation raise OSError {
  guard !self.closed else {
    raise OSError(bad_fd_errno, context="read closed directory")
  }
  let operation = directory_job(self.fd(), capacity, restart)
  attach_directory_lock(operation, self.lock)
  operation
}
