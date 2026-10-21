///|
pub struct PipeRead {
  descriptor : Fd
  priv mut closed : Bool
}

///|
pub struct PipeWrite {
  descriptor : Fd
  priv mut closed : Bool
}

///|
pub suberror PipeError

///|
extern "C" fn invalid_fd() -> Fd = "moonrun_sqlite_invalid_fd"

///|
#borrow(endpoints)
extern "C" fn create_pipe(endpoints : FixedArray[Fd]) -> Int32 = "moonrun_sqlite_pipe"

///|
extern "C" fn close_fd(fd : Fd) -> Unit = "moonrun_sqlite_pipe_close"

///|
#borrow(buffer)
extern "C" fn read_pipe(
  fd : Fd,
  buffer : FixedArray[Byte],
  length : Int32,
) -> Int32 = "moonrun_sqlite_pipe_read"

///|
pub fn pipe() -> (PipeRead, PipeWrite) raise PipeError {
  let endpoints = FixedArray::make(2, invalid_fd())
  if create_pipe(endpoints) < 0 {
    raise PipeError
  }
  (
    { descriptor: endpoints[0], closed: false, },
    { descriptor: endpoints[1], closed: false, },
  )
}

///|
pub fn PipeRead::fd(self : PipeRead) -> Fd {
  self.descriptor
}

///|
pub fn PipeWrite::fd(self : PipeWrite) -> Fd {
  self.descriptor
}

///|
pub fn PipeRead::read(
  self : PipeRead,
  buffer : FixedArray[Byte],
  max_len~ : Int32,
) -> Int32 raise PipeError {
  let count = read_pipe(self.descriptor, buffer, max_len)
  if count < 0 {
    raise PipeError
  }
  count
}

///|
pub fn PipeRead::close(self : PipeRead) -> Unit {
  if !self.closed {
    self.closed = true
    close_fd(self.descriptor)
  }
}

///|
pub fn PipeWrite::close(self : PipeWrite) -> Unit {
  if !self.closed {
    self.closed = true
    close_fd(self.descriptor)
  }
}
