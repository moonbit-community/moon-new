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
      let start = i32(args[0])
      let length = i32(args[1])
      guard start >= 0 &&
        length >= 0 &&
        start.to_int64() + length.to_int64() <= memory.byte_len() else {
        raise @vm.OutOfBoundsMemoryAccess
      }
      [self.put(Bytes(memory.read_bytes(start, length).to_fixedarray()))]
    }
    "get" => {
      let bytes = self.bytes(args[0])
      let index = i32(args[1])
      @sys.check_range(index, 1, bytes.length())
      [I32(bytes[index].to_int())]
    }
    "set" => {
      let bytes = self.bytes(args[0])
      let index = i32(args[1])
      @sys.check_range(index, 1, bytes.length())
      bytes[index] = i32(args[2]).to_byte()
      []
    }
    "length" => [I32(self.bytes(args[0]).length())]
    "equals" =>
      [I32(if self.bytes(args[0]) == self.bytes(args[1]) { 1 } else { 0 })]
    "copy" => {
      let destination = self.bytes(args[0])
      let offset = i32(args[1])
      let source = self.bytes(args[2])
      let start = i32(args[3])
      let length = i32(args[4])
      @sys.check_range(start, length, source.length())
      @sys.check_range(offset, length, destination.length())
      source.blit_to(
        destination,
        src_offset=start,
        dst_offset=offset,
        len=length,
      )
      []
    }
    "fill" => {
      let bytes = self.bytes(args[0])
      let start = i32(args[1])
      let value = i32(args[2]).to_byte()
      let length = i32(args[3])
      @sys.check_range(start, length, bytes.length())
      for index in start..<(start + length) {
        bytes[index] = value
      }
      []
    }
    "asString" => {
      let bytes = self.bytes(args[0])
      let start = i32(args[1])
      let length = i32(args[2])
      @sys.check_range(start, length, bytes.length())
      let builder = StringBuilder()
      for index in 0..<(length / 2) {
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
