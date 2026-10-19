///|
pub struct Stdio {
  stdin : (() -> Bytes)?
  stdout : ((Bytes) -> Unit)?
  stderr : ((Bytes) -> Unit)?
  priv mut input : Bytes
  priv mut input_offset : Int32
  priv mut high_surrogate : Int32?
}

///|
pub fn Stdio::Stdio(
  stdin : (() -> Bytes)?,
  stdout : ((Bytes) -> Unit)?,
  stderr : ((Bytes) -> Unit)?,
) -> Stdio {
  { stdin, stdout, stderr, input: b"", input_offset: 0, high_surrogate: None, }
}
