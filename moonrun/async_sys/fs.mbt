///|
pub extern "C" fn create_watcher() -> @types.Fd = "moonrun_watcher_create"

///|
pub extern "C" fn fd_word(fd : @types.Fd) -> Int64 = "moonrun_fd_word"

///|
pub extern "C" fn watcher_buffer_size() -> Int32 = "moonrun_watcher_buffer_size"

///|
#borrow(buffer)
pub extern "C" fn watcher_fetch(
  watcher : @types.Fd,
  buffer : FixedArray[Byte],
  length : Int32,
) -> Int32 = "moonrun_watcher_fetch"

///|
pub extern "C" fn watcher_add_file(
  watcher : @types.Fd,
  fd : @types.Fd,
  directory : Bool,
) -> Int32 = "moonrun_watcher_add_file"

///|
pub extern "C" fn watcher_remove_file(watcher : @types.Fd, wd : Int32) -> Int32 = "moonrun_watcher_remove_file"

///|
#external
pub type NativeTmpPath

///|
pub extern "C" fn native_tmp_path() -> NativeTmpPath = "moonbitlang_async_get_tmp_path"

///|
pub extern "C" fn copy_tmp_path(path : NativeTmpPath) -> Bytes = "moonrun_tmp_path"
