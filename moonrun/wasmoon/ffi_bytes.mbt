///|
fn byte_number(value : @wasm.Value) -> Double raise @vm.RuntimeError {
  match value {
    I32(value) => value.to_double()
    F64(value) => value
    _ => raise @vm.TypeMismatch
  }
}

///|
// JS slice/subarray truncate before applying relative, clamped indices.
fn relative_byte_index(index : Double, length : Int32) -> Int32 {
  let index = index.trunc()
  if index.is_nan() {
    return 0
  }
  let index = if index < 0.0 { length.to_double() + index } else { index }
  if index <= 0.0 {
    0
  } else if index >= length.to_double() {
    length
  } else {
    index.to_int()
  }
}

///|
fn ffi_bytes_signature(name : String, actual : @wasm.FuncType) -> Bool {
  guard import_signature("ffi-bytes", name) is Some(expected) else {
    return false
  }
  let params : ReadOnlyArray[@wasm.ValueType] = actual.params.mapi((index, ty) => {
    if ty is RefExtern {
      ExternRef
    } else if ty is F64 &&
      (name == "from_memory" || (name == "fill" && index is (1 | 3))) {
      I32
    } else {
      ty
    }
  })
  params == expected.params &&
  (
    actual.results == expected.results ||
    (name == "set" && actual.results is [I32]) ||
    (name == "fill" && actual.results is [ExternRef])
  )
}

///|
fn Context::ffi_bytes(
  self : Context,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  match name {
    "new" => {
      let size = i32(args[0])
      guard size >= 0 else { raise @vm.OutOfBoundsArrayAccess }
      [self.put(Bytes(FixedArray::make(size, b'\x00')))]
    }
    "from_memory" => {
      guard self.ffi_memory is Some(memory) else {
        raise @vm.OutOfBoundsMemoryAccess
      }
      let length = memory.byte_len().to_int()
      let offset = byte_number(args[0])
      let end = relative_byte_index(offset + byte_number(args[1]), length)
      let start = @cmp.minimum(relative_byte_index(offset, length), end)
      [self.put(Bytes(memory.read_bytes(start, end - start).to_fixedarray()))]
    }
    "get" => {
      let bytes = self.bytes(args[0])
      [I32(bytes.get(i32(args[1])).map(byte => byte.to_int()).unwrap_or(0))]
    }
    "set" => {
      let bytes = self.bytes(args[0])
      let index = i32(args[1])
      if index >= 0 && index < bytes.length() {
        bytes[index] = i32(args[2]).to_byte()
      }
      [args[2]]
    }
    "length" => [I32(self.bytes(args[0]).length())]
    "equals" =>
      [I32(if self.bytes(args[0]) == self.bytes(args[1]) { 1 } else { 0 })]
    "copy" => {
      let destination = self.bytes(args[0])
      let offset = i32(args[1])
      let source = self.bytes(args[2])
      let position = i32(args[3]).to_double()
      let end = relative_byte_index(
        position + i32(args[4]).to_double(),
        source.length(),
      )
      let start = @cmp.minimum(
        relative_byte_index(position, source.length()),
        end,
      )
      @sys.check_range(offset, end - start, destination.length())
      source.blit_to(
        destination,
        src_offset=start,
        dst_offset=offset,
        len=end - start,
      )
      []
    }
    "fill" => {
      let bytes = self.bytes(args[0])
      let position = byte_number(args[1])
      let end = relative_byte_index(
        position + byte_number(args[3]),
        bytes.length(),
      )
      let start = @cmp.minimum(
        relative_byte_index(position, bytes.length()),
        end,
      )
      for index in start..<end {
        bytes[index] = i32(args[2]).to_byte()
      }
      [args[0]]
    }
    "asString" => {
      let bytes = self.bytes(args[0])
      let position = i32(args[1]).to_double()
      let end = relative_byte_index(
        position + i32(args[2]).to_double(),
        bytes.length(),
      )
      let start = @cmp.minimum(
        relative_byte_index(position, bytes.length()),
        end,
      )
      let builder = StringBuilder()
      for index in 0..<((end - start) / 2) {
        let offset = start + 2 * index
        builder.write_char(
          (bytes[offset].to_int() | (bytes[offset + 1].to_int() << 8)).unsafe_to_char(),
        )
      }
      [self.put(Text(builder.to_string()))]
    }
    _ => raise @vm.UnknownImport("ffi-bytes", name)
  }
}
