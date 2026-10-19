///|
fn socket_address_signature(name : String) -> @wasm.FuncType? {
  let (params, results) : (
    ReadOnlyArray[@wasm.ValueType],
    ReadOnlyArray[@wasm.ValueType],
  ) = match name {
    "socket/ipv4_addr_size"
    | "socket/ipv6_addr_size"
    | "socket/addr_get_ipv6_bytes_offset" => ([], [I32])
    "socket/init_ip_addr" => ([I32, I32, I32], [])
    "socket/init_ipv6_addr" => ([I32, I32, I32, I32], [])
    "socket/ip_addr_get_ip"
    | "socket/ip_addr_get_port"
    | "socket/addr_is_ipv6"
    | "socket/addr_is_multicast"
    | "socket/addr_get_ipv6_scope_id"
    | "socket/addr_is_ipv6_wildcard" => ([I32, I32], [I32])
    "socket/addr_copy_ipv6_bytes" => ([I32, I32, I32, I32], [])
    _ => return None
  }
  Some({ params, results, })
}

///|
fn Context::socket_address_import(
  _self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  match name {
    "socket/ipv4_addr_size" => [I32(@sys.ipv4_address_size())]
    "socket/ipv6_addr_size" => [I32(@sys.ipv6_address_size())]
    "socket/addr_get_ipv6_bytes_offset" => [I32(@sys.ipv6_bytes_offset())]
    "socket/init_ip_addr" | "socket/init_ipv6_addr" => {
      let buffer = Bytes::make(
        if name == "socket/init_ip_addr" {
          @sys.ipv4_address_size()
        } else {
          @sys.ipv6_address_size()
        },
        0,
      )
      if name == "socket/init_ip_addr" {
        @sys.init_ipv4_address(
          buffer,
          i32(args[1]).reinterpret_as_uint(),
          i32(args[2]),
        )
      } else {
        @sys.init_ipv6_address(
          buffer,
          guest_bytes(caller, i32(args[1]), 16),
          i32(args[2]),
          i32(args[3]).reinterpret_as_uint(),
        )
      }
      guest_memory(caller).init_data_at(
        i32(args[0]).reinterpret_as_uint().to_int64(),
        buffer,
      )
      []
    }
    "socket/addr_copy_ipv6_bytes" => {
      let bytes = guest_bytes(caller, i32(args[0]), i32(args[2]))
      let address = @sys.decode_address(bytes)
      guard address.is_ipv6() && i32(args[3]) == 16 else {
        raise @vm.TypeMismatch
      }
      let offset = @sys.ipv6_bytes_offset()
      guest_memory(caller).init_data_at(
        i32(args[1]).reinterpret_as_uint().to_int64(),
        bytes[offset:offset + 16].to_owned(),
      )
      []
    }
    _ => {
      let bytes = guest_bytes(caller, i32(args[0]), i32(args[1]))
      let address = @sys.decode_address(bytes)
      let result = match name {
        "socket/ip_addr_get_ip" => {
          guard !address.is_ipv6() else { raise @vm.TypeMismatch }
          address.ip().reinterpret_as_int()
        }
        "socket/ip_addr_get_port" => address.port()
        "socket/addr_is_ipv6" => if address.is_ipv6() { 1 } else { 0 }
        "socket/addr_is_multicast" => if address.is_multicast() { 1 } else { 0 }
        "socket/addr_get_ipv6_scope_id" => {
          guard address.is_ipv6() else { raise @vm.TypeMismatch }
          @sys.buffer_word(bytes.to_fixedarray(), 24, 4).to_int()
        }
        "socket/addr_is_ipv6_wildcard" => {
          guard address.is_ipv6() else { raise @vm.TypeMismatch }
          let offset = @sys.ipv6_bytes_offset()
          if bytes[offset:offset + 16].iter().all(byte => byte == b'\x00') {
            1
          } else {
            0
          }
        }
        _ => raise @vm.UnknownImport("moonbitlang/async", name)
      }
      [I32(result)]
    }
  }
}
