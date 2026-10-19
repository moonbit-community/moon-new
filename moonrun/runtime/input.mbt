///|
let input_lock : @async.Mutex = @async.Mutex()

///|
async fn Host::read_byte(self : Host) -> Int32 {
  if self.input_offset >= self.input.length() {
    self.input = match self.stdin {
      Some(read) => read()
      None => {
        input_lock.acquire()
        defer input_lock.release()
        @stdio.stdin.read_some(max_len=4096).unwrap_or(b"")
      }
    }
    self.input_offset = 0
  }
  if self.input_offset >= self.input.length() {
    return -1
  }
  let byte = self.input[self.input_offset].to_int()
  self.input_offset += 1
  byte
}

///|
async fn Host::read_char(self : Host) -> Int32 {
  let first = self.read_byte()
  if first < 0 {
    return -1
  }
  let length = match first {
    0..<0x80 => 1
    0xC0..<=0xDF => 2
    0xE0..<=0xEF => 3
    0xF0..<=0xF7 => 4
    _ => return -1
  }
  let bytes = FixedArray::make(length, b'\x00')
  bytes[0] = first.to_byte()
  for index in 1..<length {
    let next = self.read_byte()
    if next < 0 {
      return -1
    }
    bytes[index] = next.to_byte()
  }
  @utf8.decode(Bytes::from_array(bytes)).to_array()[0].to_int() catch {
    _ => -1
  }
}

///|
async fn Host::read_all(self : Host) -> Bytes {
  let chunks = []
  if self.input_offset < self.input.length() {
    chunks.push(self.input[self.input_offset:].to_owned())
    self.input_offset = self.input.length()
  }
  match self.stdin {
    Some(read) =>
      for ;; {
        let chunk = read()
        if chunk.is_empty() {
          break
        }
        chunks.push(chunk)
      }
    None => {
      input_lock.acquire()
      defer input_lock.release()
      chunks.push(@stdio.stdin.read_all().binary())
    }
  }
  let length = chunks.fold(init=0, (length, chunk) => length + chunk.length())
  let buffer = FixedArray::make(length, b'\x00')
  let mut offset = 0
  for chunk in chunks {
    for byte in chunk {
      buffer[offset] = byte
      offset += 1
    }
  }
  Bytes::from_array(buffer)
}

///|
async fn Host::read_chunk(self : Host, length : Int32) -> Bytes {
  if length == 0 {
    return b""
  }
  if self.read_byte() < 0 {
    return b""
  }
  let start = self.input_offset - 1
  let count = @cmp.minimum(length, self.input.length() - start)
  self.input_offset = start + count
  self.input[start:self.input_offset].to_owned()
}

///|
fn Host::close(self : Host) -> Unit {
  for child in self.owned_children {
    child.close()
  }
  self.owned_children.clear()
  self.children.clear()
  for _, handle in self.process_handles {
    if handle is External(process) {
      process.release()
    }
  }
  self.process_handles.clear()
  self.process_env.clear()
  self.process_args.clear()
  for _, bus in self.buses {
    bus.close()
  }
  self.buses.clear()
  if self.pool is Some(pool) {
    pool.close()
    self.pool = None
  }
  for _, job in self.jobs {
    job.dispose()
  }
  self.jobs.clear()
  for _, worker in self.workers {
    if worker.completion is Some(fd) {
      fd.release()
    }
  }
  self.workers.clear()
  self.io_results.clear()
  self.address_info.clear()
  for _, fd in self.fds {
    fd.release()
  }
  self.fds.clear()
  if self.wasi_context is Some(context) {
    let descriptors = context.open_files.keys().collect()
    for fd in descriptors {
      ignore(context.close_fd(fd))
    }
  }
  self.values.clear()
  self.buffers.clear()
  self.pending = None
  self.ready = None
}
