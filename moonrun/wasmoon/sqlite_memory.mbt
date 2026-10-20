///|
fn sqlite_range(
  caller : @vm.Caller,
  pointer : Int32,
  length : Int64,
) -> (@vm.Memory, Int64) raise @vm.RuntimeError {
  let memory = guest_memory(caller)
  let address = pointer.reinterpret_as_uint().to_int64()
  guard pointer != 0 && length >= 0 && address + length <= memory.byte_len() else {
    raise @vm.OutOfBoundsMemoryAccess
  }
  (memory, address)
}

///|
fn sqlite_bytes(
  caller : @vm.Caller,
  pointer : Int32,
  offset : Int32,
  length : Int32,
) -> Bytes raise @vm.RuntimeError {
  let address = pointer.reinterpret_as_uint().to_int64() + offset.to_int64()
  guard pointer != 0 && offset >= 0 && length >= 0 && address <= 0xFFFF_FFFFL else {
    raise @vm.OutOfBoundsMemoryAccess
  }
  guest_bytes(caller, address.to_int(), length)
}

///|
fn sqlite_string(
  caller : @vm.Caller,
  pointer : Int32,
  offset : Int32,
  length : Int32,
) -> String raise @vm.RuntimeError {
  let address = pointer.reinterpret_as_uint().to_int64() +
    offset.to_int64() * 2L
  guard pointer != 0 &&
    (pointer & 1) == 0 &&
    offset >= 0 &&
    length >= 0 &&
    address <= 0xFFFF_FFFFL &&
    length <= 0x3FFF_FFFF else {
    raise @vm.OutOfBoundsMemoryAccess
  }
  let memory = guest_memory(caller)
  guard address + length.to_int64() * 2L <= memory.byte_len() else {
    raise @vm.OutOfBoundsMemoryAccess
  }
  let builder = StringBuilder()
  for index in 0..<length {
    builder.write_char(
      memory.load_i32_16u_at(address + index.to_int64() * 2L).unsafe_to_char(),
    )
  }
  builder.to_string()
}

///|
fn sqlite_filename(
  caller : @vm.Caller,
  pointer : Int32,
  length : Int32,
) -> Bytes raise {
  let bytes = sqlite_bytes(caller, pointer, 0, length)
  guard !bytes.iter().any(byte => byte == b'\x00') else {
    raise @vm.TypeMismatch
  }
  ignore(@utf8.decode(bytes)) catch {
    _ => raise @vm.TypeMismatch
  }
  bytes
}

///|
fn sqlite_copy_string(
  caller : @vm.Caller,
  pointer : Int32,
  capacity : Int32,
  value : String,
) -> Int32 raise @vm.RuntimeError {
  guard capacity >= 0 && capacity <= 0x7FFF_FFFF / 2 else {
    raise @vm.OutOfBoundsMemoryAccess
  }
  if capacity == 0 {
    return value.length()
  }
  guard (pointer & 1) == 0 else { raise @vm.OutOfBoundsMemoryAccess }
  let (memory, address) = sqlite_range(
    caller,
    pointer,
    capacity.to_int64() * 2L,
  )
  if capacity >= value.length() {
    for index in 0..<value.length() {
      memory.store_i32_16_at(
        address + index.to_int64() * 2L,
        value[index].to_int(),
      )
    }
  }
  value.length()
}

///|
fn sqlite_copy_bytes(
  caller : @vm.Caller,
  pointer : Int32,
  capacity : Int32,
  value : Bytes,
) -> Int32 raise @vm.RuntimeError {
  guard capacity >= 0 else { raise @vm.OutOfBoundsMemoryAccess }
  if capacity == 0 {
    return value.length()
  }
  let (memory, address) = sqlite_range(caller, pointer, capacity.to_int64())
  if capacity >= value.length() {
    memory.init_data_at(address, value)
  }
  value.length()
}
