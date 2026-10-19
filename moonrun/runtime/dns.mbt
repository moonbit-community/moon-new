///|
priv struct GuestAddrInfo {
  address : Bytes
  next : Int64
}

///|
extern "C" fn gai_message(code : Int32) -> Bytes = "moonrun_gai_message"

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
fn Host::dns_import(
  self : Host,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  match name {
    "thread_pool/make_getaddrinfo_job" => {
      let host = guest_string(caller, i32(args[0]), i32(args[1]))
      self.new_job(() => self.resolve_hostname(host))
    }
    "thread_pool/get_getaddrinfo_result" => {
      guard self.jobs.get(i64(args[0])) is Some(job) &&
        !job.running &&
        job.result is Some(result) &&
        result.ret == 0 &&
        result.errno == 0 else {
        raise @vm.TypeMismatch
      }
      if job.result_handle is Some(ResolvedAddresses(handle)) {
        return [I64(handle)]
      }
      guard job.result_handle is None else { raise @vm.TypeMismatch }
      let addresses : Array[Bytes] = []
      let data = result.data.to_fixedarray()
      let mut offset = 0
      while offset < data.length() {
        let length = buffer_word(data, offset, 4).to_int()
        check_range(offset + 4, length, data.length())
        let address = result.data[offset + 4:offset + 4 + length].to_owned()
        ignore(decode_address(address))
        addresses.push(address)
        offset += 4 + length
      }
      let mut next = 0L
      for index = addresses.length() - 1; index >= 0; index = index - 1 {
        let handle = self.next_handle
        self.next_handle += 1L
        self.address_info[handle] = { address: addresses[index], next, }
        next = handle
      }
      job.result_handle = Some(ResolvedAddresses(next))
      [I64(next)]
    }
    "socket/addrinfo_is_null" => [I32(if i64(args[0]) == 0L { 1 } else { 0 })]
    "socket/addrinfo_free" => {
      let mut handle = i64(args[0])
      while self.address_info.get(handle) is Some(entry) {
        self.address_info.remove(handle)
        handle = entry.next
      }
      []
    }
    "socket/gai_strerror" => {
      let data = gai_message(i32(args[0]))
      let handle = self.next_handle
      self.next_handle += 1L
      self.buffers[handle] = data.to_fixedarray()
      [I64(handle)]
    }
    _ => {
      guard self.address_info.get(i64(args[0])) is Some(info) else {
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
