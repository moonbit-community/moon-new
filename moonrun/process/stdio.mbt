///|
priv struct ChildStream {
  pipe : @raw_fd.RawFd
  index : Int32
  id : Int32
  mut closed : Bool
}

///|
fn ChildStream::close(self : ChildStream) -> Unit {
  if !self.closed {
    self.closed = true
    self.pipe.close()
  }
}

///|
async fn HostProcess::forward_child_stream(
  self : HostProcess,
  stream : ChildStream,
) -> Unit {
  let pipe = stream.pipe
  if stream.index == 0 {
    defer stream.close()
    try {
      for ;; {
        let data = self.stdio.read_chunk(4096)
        if data.is_empty() {
          break
        }
        let mut offset = 0
        while offset < data.length() {
          offset += pipe.write(data, offset~, len=data.length() - offset)
        }
      }
    } catch {
      @os_error.OSError(code, ..) if (if @async.platform is Windows {
          code is (109 | 232 | 233)
        } else {
          code == 32
        }) => ()
      error => raise error
    }
  } else {
    let buffer = FixedArray::make(4096, b'\x00')
    let finished = @async.handle_cancellation(() => {
      for ;; {
        let count = pipe.read(buffer)
        if count == 0 {
          break
        }
        self.stdio.output(stream.id, Bytes::from_array(buffer[:count]))
      }
    })
    if finished is None {
      // Preserve bytes produced before cancellation, without waiting for EOF
      // from descendants which may still hold a copy of the output writer.
      @async.protect_from_cancel(() => {
        let mut remaining = @sys.buffered_pipe_bytes(pipe.fd)
        if remaining < 0 {
          @os_error.check_errno("child output buffer")
        }
        while remaining > 0 {
          let count = pipe.read(
            buffer,
            max_len=@cmp.minimum(remaining, buffer.length()),
          )
          if count == 0 {
            break
          }
          self.stdio.output(stream.id, Bytes::from_array(buffer[:count]))
          remaining -= count
        }
      })
    } else {
      stream.close()
    }
  }
}

///|
async fn HostProcess::child_stream(
  self : HostProcess,
  descriptor : @resource.Resource?,
  index : Int32,
) -> (@types.Fd, @raw_fd.RawFd, Int32)? {
  let id = match descriptor {
    None => index
    Some(fd) =>
      match fd.owner {
        Standard(id, _) => id
        _ => return None
      }
  }
  if !(if id == 0 {
      self.stdio.stdin is Some(_)
    } else if id == 1 {
      self.stdio.stdout is Some(_)
    } else {
      self.stdio.stderr is Some(_)
    }) {
    return None
  }
  let endpoints = FixedArray::make(2, @sys.invalid_native_fd())
  if @sys.create_guest_pipe(endpoints, false, false) < 0 {
    @os_error.check_errno("process callback pipe")
  }
  let child = endpoints[if index == 0 { 0 } else { 1 }]
  errdefer ignore(@sys.close_guest_pipe(child))
  let pipe = @async.protect_from_cancel(() => {
    @raw_fd.RawFd(endpoints[if index == 0 { 1 } else { 0 }])
  })
  Some((child, pipe, id))
}
