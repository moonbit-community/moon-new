///|
fn dns_signature(name : String) -> @wasm.FuncType? {
  let (params, results) : (
    ReadOnlyArray[@wasm.ValueType],
    ReadOnlyArray[@wasm.ValueType],
  ) = match name {
    "thread_pool/make_getaddrinfo_job" => ([I32, I32], [I64])
    "thread_pool/get_getaddrinfo_result" | "socket/addrinfo_get_next" =>
      ([I64], [I64])
    "socket/addrinfo_is_null" | "socket/addrinfo_addr_size" => ([I64], [I32])
    "socket/addrinfo_fill_addr" => ([I64, I32, I32, I32], [])
    "socket/addrinfo_free" => ([I64], [])
    "socket/gai_strerror" => ([I32], [I64])
    _ => return None
  }
  Some({ params, results, })
}

///|
fn Context::dns_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  match name {
    "thread_pool/make_getaddrinfo_job" => {
      let host = guest_string(caller, i32(args[0]), i32(args[1]))
      [
        I64(
          self.runtime.async_host.new_job(() => {
            self.runtime.network.resolve_hostname(host)
          }),
        ),
      ]
    }
    "thread_pool/get_getaddrinfo_result" =>
      [I64(self.runtime.async_host.addrinfo_result(i64(args[0])))]
    "socket/addrinfo_is_null" =>
      [
        I32(
          if i64(args[0]) == self.runtime.handles.null_handle {
            1
          } else {
            0
          },
        ),
      ]
    "socket/addrinfo_free" => {
      let mut handle = i64(args[0])
      if handle == self.runtime.handles.null_handle {
        return []
      }
      guard self.runtime.async_host.address_info.contains(handle) else {
        raise @sys.Operation("Badf")
      }
      while self.runtime.async_host.address_info.get(handle) is Some(entry) {
        self.runtime.async_host.address_info.remove(handle)
        handle = entry.next
      }
      []
    }
    "socket/gai_strerror" => {
      let data = @sys.gai_message(i32(args[0]))
      let handle = self.runtime.handles.allocate()
      self.runtime.async_host.buffers[handle] = data.to_fixedarray()
      [I64(handle)]
    }
    _ => {
      if i64(args[0]) == self.runtime.handles.null_handle {
        if name == "socket/addrinfo_get_next" {
          return [I64(self.runtime.handles.null_handle)]
        }
        if name == "socket/addrinfo_addr_size" {
          return [I32(0)]
        }
      }
      guard self.runtime.async_host.address_info.get(i64(args[0])) is Some(info) else {
        raise @vm.TypeMismatch
      }
      match name {
        "socket/addrinfo_get_next" => [I64(info.next)]
        "socket/addrinfo_addr_size" => [I32(info.address.length())]
        "socket/addrinfo_fill_addr" => {
          guard i32(args[3]) >= info.address.length() else {
            raise @vm.OutOfBoundsMemoryAccess
          }
          let address = info.address.to_fixedarray()
          let port = i32(args[2])
          address[2] = (port >> 8).to_byte()
          address[3] = port.to_byte()
          guest_memory(caller).init_data_at(
            i32(args[1]).reinterpret_as_uint().to_int64(),
            Bytes::from_array(address),
          )
          []
        }
        _ => raise @vm.UnknownImport("moonbitlang/async", name)
      }
    }
  }
}
