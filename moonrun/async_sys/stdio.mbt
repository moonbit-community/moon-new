///|
pub struct StandardStream {
  descriptor : Int32
}

///|
pub let stdin : StandardStream = { descriptor: 0, }

///|
pub let stdout : StandardStream = { descriptor: 1, }

///|
pub let stderr : StandardStream = { descriptor: 2, }

///|
pub trait BytesLike {
  fn bytes(Self) -> Bytes
}

///|
pub impl BytesLike for Bytes with fn bytes(self) {
  self
}

///|
pub impl BytesLike for String with fn bytes(self) {
  @utf8.encode(self)
}

///|
pub fn[T : BytesLike] StandardStream::write(
  self : StandardStream,
  value : T,
) -> Unit raise {
  let data = value.bytes()
  let mut offset = 0
  while offset < data.length() {
    let operation = write_job(
      standard_fd(self.descriptor),
      data[offset:].to_owned(),
      -1L,
    )
    defer operation.close()
    operation.run()
    if operation.ret() < 0 {
      raise OSError(operation.error(), context="standard output")
    }
    let count = operation.ret()
    if count <= 0 {
      check_errno("standard output")
    }
    offset += count
  }
}

///|
pub fn StandardStream::read_some(
  self : StandardStream,
  max_len~ : Int32,
) -> Bytes? raise {
  let data = checked(
    read_job(standard_fd(self.descriptor), max_len, -1L),
    "standard input",
  )
  if data.is_empty() {
    None
  } else {
    Some(data)
  }
}

///|
pub fn StandardStream::read_all(self : StandardStream) -> Bytes raise {
  let output = @buffer.Buffer()
  for ;; {
    match self.read_some(max_len=65536) {
      Some(bytes) => output.write_bytes(bytes)
      None => break
    }
  }
  output.to_bytes()
}

///|
pub fn StandardStream::fd(self : StandardStream) -> Fd {
  standard_fd(self.descriptor)
}
