///|
fn Context::temporary_path_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.async_host
  if self.runtime.policy is Some(_) &&
    @sys.platform is Windows &&
    ["TMP", "TEMP"].all(key => {
      @environment.environment_entry(self.runtime.env, key)
      .map(entry => entry.1.is_empty())
      .unwrap_or(true)
    }) {
    host.async_errno = 5
    return if name == "fs/get_tmp_path_buffer" {
      [I64(self.runtime.handles.null_handle)]
    } else {
      [I32(-1)]
    }
  }
  let path = self.runtime.filesystem.temporary_path()
  match name {
    "fs/get_tmp_path_len" => [I32(path.length())]
    "fs/get_tmp_path" => {
      guard i32(args[1]) == path.length() else {
        host.async_errno = if @sys.platform is Windows { 87 } else { 22 }
        return [I32(-1)]
      }
      let data = @utf16.encode(path, endianness=Little, bom=false)
      let pointer = i32(args[0]).reinterpret_as_uint().to_int64()
      guard pointer + data.length().to_int64() <=
        guest_memory(caller).byte_len() else {
        host.async_errno = @sys.fault_errno
        return [I32(-1)]
      }
      guest_memory(caller).init_data_at(pointer, data)
      [I32(0)]
    }
    _ => {
      let handle = self.runtime.handles.allocate()
      host.buffers[handle] = (if @sys.platform is Windows {
        @utf16.encode(path + "\u0000", endianness=Little, bom=false)
      } else {
        @utf8.encode(path + "\u0000")
      }).to_fixedarray()
      [I64(handle)]
    }
  }
}
