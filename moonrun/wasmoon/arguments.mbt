///|
fn i64(value : @wasm.Value) -> Int64 raise @vm.RuntimeError {
  guard value is I64(value) else { raise @vm.TypeMismatch }
  value
}

///|
fn i32(value : @wasm.Value) -> Int32 raise @vm.RuntimeError {
  guard value is I32(value) else { raise @vm.TypeMismatch }
  value
}
