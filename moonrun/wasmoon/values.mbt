///|
priv enum HostValue {
  Text(String)
  Bytes(FixedArray[Byte])
  Strings(Array[String])
  Builder(StringBuilder)
  ByteBuilder(Array[Byte])
  TextReader(String, Ref[Int32])
  ByteReader(FixedArray[Byte], Ref[Int32])
  StringReader(Array[String], Ref[Int32])
  Instant(Int64)
  HostError(@vm.RuntimeError)
}

///|
fn Context::put(self : Context, value : HostValue) -> @wasm.Value {
  let index = self.values.length()
  self.values.push(value)
  ExternRef(index)
}

///|
fn Context::get(
  self : Context,
  value : @wasm.Value,
) -> HostValue raise @vm.RuntimeError {
  guard value is ExternRef(index) && self.values.get(index) is Some(value) else {
    raise @vm.TypeMismatch
  }
  value
}

///|
fn Context::text(
  self : Context,
  value : @wasm.Value,
) -> String raise @vm.RuntimeError {
  guard self.get(value) is Text(text) else { raise @vm.TypeMismatch }
  text
}

///|
fn Context::bytes(
  self : Context,
  value : @wasm.Value,
) -> FixedArray[Byte] raise @vm.RuntimeError {
  guard self.get(value) is Bytes(bytes) else { raise @vm.TypeMismatch }
  bytes
}
