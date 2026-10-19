///|
// POSIX EBADF/EFAULT and Win32 ERROR_INVALID_HANDLE/ERROR_INVALID_ADDRESS.
pub let bad_fd_errno : Int32 = if @async.platform is Windows { 6 } else { 9 }

///|
pub let fault_errno : Int32 = if @async.platform is Windows { 487 } else { 14 }

///|
pub extern "C" fn invalid_native_fd() -> @types.Fd = "moonrun_invalid_fd"

///|
#borrow(endpoints)
pub extern "C" fn create_guest_pipe(
  endpoints : FixedArray[@types.Fd],
  read_async : Bool,
  write_async : Bool,
) -> Int32 = "moonrun_create_pipe"

///|
pub extern "C" fn close_guest_pipe(fd : @types.Fd) -> Int32 = "moonrun_close_pipe"

///|
pub extern "C" fn fd_cloexec(fd : @types.Fd) -> Int32 = "moonrun_fd_cloexec"

///|
#borrow(buffer)
pub extern "C" fn read_guest_pipe(
  fd : @types.Fd,
  buffer : FixedArray[Byte],
  length : Int32,
) -> Int32 = "moonrun_pipe_read"

///|
#borrow(buffer)
pub extern "C" fn write_guest_pipe(
  fd : @types.Fd,
  buffer : FixedArray[Byte],
  length : Int32,
) -> Int32 = "moonrun_pipe_write"

///|
pub extern "C" fn fd_nonblocking(fd : @types.Fd) -> Int32 = "moonrun_fd_nonblocking"
