///|
pub async fn Resource::read_job(
  self : Resource,
  length : Int32,
  position : Int64,
  flags~ : Int32 = 0,
) -> JobResult {
  self.read_lock.acquire()
  defer self.read_lock.release()
  let buffer = FixedArray::make(length, b'\x00')
  let count = match self.owner {
    Socket(socket) => socket.read(buffer, flags)
    Pipe(pipe, true) => {
      if position != -1L {
        raise @os_error.OSError(
          if @async.platform is Windows {
            87
          } else {
            29
          },
          context="pipe read position",
        )
      }
      pipe.read(buffer)
    }
    Pipe(_, false) =>
      raise @os_error.OSError(
        @sys.bad_fd_errno,
        context="read from pipe writer",
      )
    Standard(_, _) | Watcher(_) =>
      raise @os_error.OSError(
        @sys.bad_fd_errno,
        context="standard input adapter",
      )
    File(file) =>
      if position == -1L && !(file.kind() is Regular) {
        file.read(buffer)
      } else if position == -1L {
        self.cursor_lock.acquire()
        defer self.cursor_lock.release()
        let count = file.read_at(buffer, position=self.cursor)
        self.cursor += count.to_int64()
        count
      } else {
        file.read_at(buffer, position~)
      }
  }
  {
    ret: count,
    errno: 0,
    data: Bytes::from_array(buffer[:count]),
    opened: None,
  }
}

///|
pub async fn Resource::write_job(
  self : Resource,
  data : Bytes,
  position : Int64,
  flags~ : Int32 = 0,
) -> JobResult {
  self.write_lock.acquire()
  defer self.write_lock.release()
  let count = match self.owner {
    Socket(socket) => socket.write(data, flags)
    Pipe(pipe, false) => {
      if position != -1L {
        raise @os_error.OSError(
          if @async.platform is Windows {
            87
          } else {
            29
          },
          context="pipe write position",
        )
      }
      pipe.write(data)
    }
    Pipe(_, true) =>
      raise @os_error.OSError(@sys.bad_fd_errno, context="write to pipe reader")
    Standard(_, _) | Watcher(_) =>
      raise @os_error.OSError(
        @sys.bad_fd_errno,
        context="standard output adapter",
      )
    File(file) =>
      if position == -1L && !(file.kind() is Regular) {
        file.write_once(data, offset=0, len=data.length())
      } else if position == -1L {
        self.cursor_lock.acquire()
        defer self.cursor_lock.release()
        let count = if self.append {
          file.write_once(data, offset=0, len=data.length())
        } else {
          file.write_at(data, position=self.cursor)
          data.length()
        }
        self.cursor = if self.append {
          file.size()
        } else {
          self.cursor + count.to_int64()
        }
        count
      } else {
        if self.append {
          raise @os_error.OSError(
            if @async.platform is Windows {
              87
            } else {
              22
            },
            context="positioned append write",
          )
        }
        file.write_at(data, position~)
        data.length()
      }
  }
  { ret: count, errno: 0, data: b"", opened: None, }
}
