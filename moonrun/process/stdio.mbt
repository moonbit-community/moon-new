///|
priv struct ChildStream {
  pipe : @sys.Fd
  index : Int32
  id : Int32
  mut closed : Bool
  mut input : Bytes
  mut offset : Int32
}

///|
fn ChildStream::close(self : ChildStream) -> Unit {
  if !self.closed {
    self.closed = true
    ignore(@sys.close_guest_pipe(self.pipe))
  }
}

///|
fn HostProcess::child_stream(
  self : HostProcess,
  descriptor : @resource.Resource?,
  index : Int32,
) -> (@sys.Fd, @sys.Fd, Int32)? raise {
  let id = match descriptor {
    None => index
    Some(fd) =>
      match fd.owner {
        Standard(id, _) => id
        _ => return None
      }
  }
  if !(match id {
      0 => self.stdio.stdin is Some(_)
      1 => self.stdio.stdout is Some(_)
      _ => self.stdio.stderr is Some(_)
    }) {
    return None
  }
  let endpoints = FixedArray::make(2, @sys.invalid_native_fd())
  if @sys.create_guest_pipe(endpoints, false, false) < 0 {
    @sys.check_errno("process callback pipe")
  }
  let child = endpoints[if index == 0 { 0 } else { 1 }]
  errdefer ignore(@sys.close_guest_pipe(child))
  let parent = endpoints[if index == 0 { 1 } else { 0 }]
  if (!(@sys.platform is Windows) || index == 0) &&
    @sys.fd_nonblocking(parent) < 0 {
    ignore(@sys.close_guest_pipe(parent))
    @sys.check_errno("process callback pipe mode")
  }
  Some((child, parent, id))
}

///|
pub fn HostProcess::pump(self : HostProcess) -> Unit raise {
  for child in self.owned_children {
    for stream in child.streams {
      if stream.closed {
        continue
      }
      if stream.index == 0 {
        if stream.offset == stream.input.length() {
          stream.input = self.stdio.read_chunk(4096)
          stream.offset = 0
          if stream.input.is_empty() {
            stream.close()
            continue
          }
        }
        let data = stream.input[stream.offset:].to_owned().to_fixedarray()
        let count = @sys.write_guest_pipe(stream.pipe, data, data.length())
        if count > 0 {
          stream.offset += count
        } else if count < 0 {
          let error = @sys.OSError(@sys.get_errno(), context="process stdin")
          if error.is_nonblocking_io_error() ||
            error.is_EINTR() ||
            (@sys.platform is Windows && error is @sys.OSError(232, ..)) {
            continue
          }
          // A child may stop reading before consuming all callback input.
          if error is @sys.OSError(code, ..) &&
            (if @sys.platform is Windows {
              code is (109 | 232 | 233)
            } else {
              code == 32
            }) {
            stream.close()
          } else {
            raise error
          }
        }
      } else {
        // Drain a finite snapshot. Descendants may keep the writer open.
        let mut remaining = @sys.buffered_pipe_bytes(stream.pipe)
        if remaining < 0 {
          let error = @sys.OSError(
            @sys.get_errno(),
            context="child output buffer",
          )
          if error.is_EINTR() {
            continue
          }
          raise error
        }
        while remaining > 0 {
          let buffer = FixedArray::make(@cmp.minimum(remaining, 65536), b'\x00')
          let count = @sys.read_guest_pipe(stream.pipe, buffer, buffer.length())
          if count < 0 {
            let error = @sys.OSError(@sys.get_errno(), context="child output")
            if error.is_EINTR() || error.is_nonblocking_io_error() {
              break
            }
            raise error
          }
          if count == 0 {
            stream.close()
            break
          }
          self.stdio.output(stream.id, Bytes::from_array(buffer[:count]))
          remaining -= count
        }
        if @sys.pipe_eof(stream.pipe) {
          stream.close()
        }
      }
    }
    if !child.closed && child.result is None && @sys.child_exited(child.native) {
      @sys.join_child(child.native)
      child.result = Some(@sys.child_status(child.native))
      child.error = @sys.child_error(child.native)
    }
  }
  for index = self.owned_children.length() - 1; index >= 0; index = index - 1 {
    let child = self.owned_children[index]
    if child.closed && child.streams.all(stream => stream.closed) {
      if self.children.get(child.pid) is Some(current) &&
        current.identity == child.identity {
        self.children.remove(child.pid)
      }
      self.owned_children.remove(index) |> ignore
    }
  }
}
