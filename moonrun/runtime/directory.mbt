///|
fn buffer_word(
  buffer : FixedArray[Byte],
  offset : Int32,
  width : Int32,
) -> Int64 raise @vm.RuntimeError {
  check_range(offset, width, buffer.length())
  let mut value = 0UL
  for index in 0..<width {
    value = value | (buffer[offset + index].to_uint64() << (index * 8))
  }
  value.reinterpret_as_int64()
}

///|
fn directory_signature(name : String) -> @wasm.FuncType? {
  let (params, results) : (
    ReadOnlyArray[@wasm.ValueType],
    ReadOnlyArray[@wasm.ValueType],
  ) = match name {
    "fs/dir_buffer_min_size" => ([], [I32])
    "fs/dir_entry_length"
    | "fs/dir_entry_get_name_len"
    | "fs/dir_entry_get_name_offset"
    | "fs/dir_entry_is_dir"
    | "fs/dir_entry_is_hidden" => ([I64, I32], [I32])
    "fs/dir_entry_get_file_id" => ([I64, I32], [I64])
    _ => return None
  }
  Some({ params, results, })
}

///|
fn Host::directory_import(
  self : Host,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  if name == "fs/dir_buffer_min_size" {
    return [I32(if @async.platform is Windows { 632 } else { 299 })]
  }
  guard self.buffers.get(i64(args[0])) is Some(buffer) else {
    raise @vm.TypeMismatch
  }
  let offset = i32(args[1])
  let word = (position, width) => buffer_word(buffer, position, width)
  let (record_length, name_offset, name_length, is_dir, is_hidden, identity) = match
    @async.platform {
    Linux => {
      check_range(offset, 19, buffer.length())
      let length = word(offset + 16, 2).to_int()
      check_range(offset, length, buffer.length())
      guard length >= 20 else { raise @vm.OutOfBoundsMemoryAccess }
      let mut name_length = 0
      while name_length < length - 19 &&
            buffer[offset + 19 + name_length] != b'\x00' {
        name_length += 1
      }
      guard name_length < length - 19 else { raise @vm.OutOfBoundsMemoryAccess }
      let kind = buffer[offset + 18].to_int()
      (
        length,
        19,
        name_length,
        if kind == 0 {
          -1
        } else if kind == 4 {
          1
        } else {
          0
        },
        buffer[offset + 19] == b'.',
        word(offset, 8),
      )
    }
    MacOS => {
      check_range(offset, 44, buffer.length())
      let length = word(offset, 4).to_int()
      check_range(offset, length, buffer.length())
      let name_offset = 24L + word(offset + 24, 4)
      let name_length = word(offset + 28, 4).to_int() - 1
      guard name_offset >= 44L &&
        name_length >= 0 &&
        name_offset + name_length.to_int64() + 1L <= length.to_int64() else {
        raise @vm.OutOfBoundsMemoryAccess
      }
      let kind = word(offset + 32, 4).to_int()
      let known = (word(offset + 4, 4).to_int() & 8) != 0
      (
        length,
        name_offset.to_int(),
        name_length,
        if !known || kind == 0 {
          -1
        } else if kind == 2 {
          1
        } else {
          0
        },
        buffer[offset + name_offset.to_int()] == b'.',
        word(offset + 36, 8),
      )
    }
    Windows => {
      check_range(offset, 104, buffer.length())
      let length = word(offset, 4).to_int()
      let name_length = word(offset + 60, 4).to_int()
      let attributes = word(offset + 56, 4).to_int()
      check_range(offset + 104, name_length, buffer.length())
      if length != 0 {
        check_range(offset, length, buffer.length())
        guard length >= 104 + name_length else {
          raise @vm.OutOfBoundsMemoryAccess
        }
      }
      (
        length,
        104,
        name_length,
        if (attributes & 0x410) == 0x10 {
          1
        } else {
          0
        },
        (attributes & 2) != 0,
        word(offset + 96, 8),
      )
    }
  }
  if name == "fs/dir_entry_get_file_id" {
    return [I64(identity)]
  }
  [
    I32(
      match name {
        "fs/dir_entry_length" => record_length
        "fs/dir_entry_get_name_offset" => name_offset
        "fs/dir_entry_get_name_len" => name_length
        "fs/dir_entry_is_dir" => is_dir
        "fs/dir_entry_is_hidden" => if is_hidden { 1 } else { 0 }
        _ => raise @vm.UnknownImport("moonbitlang/async", name)
      },
    ),
  ]
}
