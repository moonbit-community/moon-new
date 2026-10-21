///|
fn Stdio::read_byte(self : Stdio) -> Int32 raise {
  if self.input_offset >= self.input.length() {
    self.input = match self.stdin {
      Some(read) => read()
      None => @sys.stdin.read_some(max_len=4096).unwrap_or(b"")
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
pub fn Stdio::read_char(self : Stdio) -> Int32 raise {
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
pub fn Stdio::read_all(self : Stdio) -> Bytes raise {
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
    None => chunks.push(@sys.stdin.read_all())
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
pub fn Stdio::read_chunk(self : Stdio, length : Int32) -> Bytes raise {
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
