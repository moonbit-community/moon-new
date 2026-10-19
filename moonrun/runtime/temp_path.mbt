///|
#external
priv type NativeTmpPath

///|
extern "C" fn native_tmp_path() -> NativeTmpPath = "moonbitlang_async_get_tmp_path"

///|
extern "C" fn copy_tmp_path(path : NativeTmpPath) -> Bytes = "moonrun_tmp_path"

///|
fn Host::temporary_path(self : Host) -> String raise @vm.RuntimeError {
  let from_env = if @async.platform is Windows {
    match
      environment_entry(self.env, "TMP")
      .map(entry => entry.1)
      .filter(path => !path.is_empty()) {
      Some(path) => Some(path)
      None =>
        environment_entry(self.env, "TEMP")
        .map(entry => entry.1)
        .filter(path => !path.is_empty())
    }
  } else {
    self.env.get("TMPDIR").filter(path => !path.is_empty())
  }
  let path = match from_env {
    Some(path) => path
    None => {
      let buffer = copy_tmp_path(native_tmp_path())
      guard !buffer.is_empty() else {
        raise @vm.LinkErrorDetail("failed to obtain temporary directory")
      }
      if @async.platform is Windows {
        @utf16.decode(buffer, endianness=Little) catch {
          _ => raise @vm.TypeMismatch
        }
      } else {
        @utf8.decode(buffer) catch {
          _ => raise @vm.TypeMismatch
        }
      }
    }
  }
  if path.has_suffix("/") ||
    (@async.platform is Windows && path.has_suffix("\\")) {
    path
  } else {
    path + (if @async.platform is Windows { "\\" } else { "/" })
  }
}

///|
fn Host::temporary_path_import(
  self : Host,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  if self.policy is Some(_) &&
    @async.platform is Windows &&
    ["TMP", "TEMP"].all(key => {
      environment_entry(self.env, key)
      .map(entry => entry.1.is_empty())
      .unwrap_or(true)
    }) {
    self.async_errno = 5
    return if name == "fs/get_tmp_path_buffer" { [I64(0L)] } else { [I32(-1)] }
  }
  let path = self.temporary_path()
  match name {
    "fs/get_tmp_path_len" => [I32(path.length())]
    "fs/get_tmp_path" => {
      guard i32(args[1]) == path.length() else {
        self.async_errno = if @async.platform is Windows { 87 } else { 22 }
        return [I32(-1)]
      }
      let data = @utf16.encode(path, endianness=Little, bom=false)
      let pointer = i32(args[0]).reinterpret_as_uint().to_int64()
      guard pointer + data.length().to_int64() <=
        guest_memory(caller).byte_len() else {
        self.async_errno = fault_errno
        return [I32(-1)]
      }
      guest_memory(caller).init_data_at(pointer, data)
      [I32(0)]
    }
    _ => {
      let handle = self.next_handle
      self.next_handle += 1L
      self.buffers[handle] = (if @async.platform is Windows {
        @utf16.encode(path + "\u0000", endianness=Little, bom=false)
      } else {
        @utf8.encode(path + "\u0000")
      }).to_fixedarray()
      [I64(handle)]
    }
  }
}
