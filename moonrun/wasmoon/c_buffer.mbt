///|
fn Context::buffer_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.async_host
  match name {
    "time/get_ms_since_epoch" => [I64(@sys.now())]
    "os_error/get_errno" => [I32(host.async_errno)]
    "c_buffer/is_null" =>
      [
        I32(
          if i64(args[0]) == self.runtime.handles.null_handle {
            1
          } else {
            0
          },
        ),
      ]
    "c_buffer/length" | "c_buffer/strlen" | "c_buffer/c_buffer_get" => {
      guard host.buffers.get(i64(args[0])) is Some(buffer) else {
        raise @vm.TypeMismatch
      }
      let value = match name {
        "c_buffer/length" => buffer.length()
        "c_buffer/c_buffer_get" => {
          let index = i32(args[1])
          @sys.check_range(index, 1, buffer.length())
          buffer[index].to_int()
        }
        _ => {
          let mut length = 0
          while length < buffer.length() && buffer[length] != b'\x00' {
            length += 1
          }
          guard length < buffer.length() else {
            raise @vm.OutOfBoundsMemoryAccess
          }
          length
        }
      }
      [I32(value)]
    }
    "c_buffer/new" => {
      let length = i32(args[0])
      guard length >= 0 else { raise @vm.OutOfBoundsMemoryAccess }
      let handle = self.runtime.handles.allocate()
      host.buffers[handle] = FixedArray::make(length, b'\x00')
      [I64(handle)]
    }
    "c_buffer/free" => {
      let handle = i64(args[0])
      if handle != self.runtime.handles.null_handle {
        guard host.buffers.contains(handle) else { raise @vm.TypeMismatch }
        host.buffers.remove(handle)
      }
      []
    }
    "c_buffer/blit_to_c" | "c_buffer/blit_from_c" => {
      guard host.buffers.get(i64(args[0])) is Some(buffer) else {
        raise @vm.TypeMismatch
      }
      let offset = i32(args[1])
      let length = i32(args[4])
      @sys.check_range(offset, length, buffer.length())
      let memory = guest_memory(caller)
      let address = i32(args[2]).reinterpret_as_uint().to_int64() +
        i32(args[3]).reinterpret_as_uint().to_int64()
      guard address + length.to_int64() <= memory.byte_len() else {
        raise @vm.OutOfBoundsMemoryAccess
      }
      if name == "c_buffer/blit_to_c" {
        memory
        .read_bytes(address.to_int(), length)
        .to_fixedarray()
        .blit_to(buffer, dst_offset=offset, len=length)
      } else {
        memory.init_data_at(
          address,
          Bytes::from_array(buffer[offset:offset + length]),
        )
      }
      []
    }
    _ => raise @vm.UnknownImport("moonbitlang/async", name)
  }
}
