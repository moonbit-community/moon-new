///|
pub fn Stdio::output(self : Stdio, fd : Int32, bytes : Bytes) -> Unit raise {
  let callback = if fd == 2 { self.stderr } else { self.stdout }
  if callback is Some(write) {
    write(bytes)
  } else if fd == 2 {
    @sys.stderr.write(bytes)
  } else {
    @sys.stdout.write(bytes)
  }
}

///|
pub fn Stdio::print_unit(self : Stdio, unit : Int32) -> Unit raise {
  // Preserve the Rust runner UTF-16 writer, including a pending high surrogate
  // across intervening scalar output.
  if unit >= 0xD800 && unit <= 0xDBFF {
    if self.high_surrogate is Some(_) {
      self.output(1, b"\xef\xbf\xbd")
    }
    self.high_surrogate = Some(unit)
    return
  }
  let codepoint = if unit >= 0xDC00 && unit <= 0xDFFF {
    let high = self.high_surrogate
    self.high_surrogate = None
    match high {
      Some(high) => 0x10000 + ((high - 0xD800) << 10) + unit - 0xDC00
      None => 0xFFFD
    }
  } else {
    unit
  }
  guard codepoint >= 0 && codepoint <= 0x10FFFF else { raise @sys.Invalid }
  self.output(1, @utf8.encode(codepoint.unsafe_to_char().to_string()))
}
