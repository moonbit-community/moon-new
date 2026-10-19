///|
extern "C" fn ipv4_address_size() -> Int32 = "moonbitlang_async_ipv4_addr_size"

///|
extern "C" fn ipv6_address_size() -> Int32 = "moonbitlang_async_ipv6_addr_size"

///|
extern "C" fn ipv6_bytes_offset() -> Int32 = "moonbitlang_async_addr_get_ipv6_bytes_offset"

///|
#borrow(buffer)
extern "C" fn init_ipv4_address(
  buffer : Bytes,
  ip : UInt32,
  port : Int32,
) -> Unit = "moonbitlang_async_init_ip_addr"

///|
#borrow(buffer, ip)
extern "C" fn init_ipv6_address(
  buffer : Bytes,
  ip : Bytes,
  port : Int32,
  scope : UInt32,
) -> Unit = "moonbitlang_async_init_ipv6_addr"

///|
fn decode_address(bytes : Bytes) -> @socket.Addr raise @vm.RuntimeError {
  let buffer = bytes.to_fixedarray()
  check_range(0, 2, buffer.length())
  let family = if @async.platform is MacOS {
    buffer[1].to_int()
  } else {
    buffer_word(buffer, 0, 2).to_int()
  }
  guard family == 2 ||
    family ==
    (match @async.platform {
      Linux => 10
      MacOS => 30
      Windows => 23
    }) else {
    raise @vm.TypeMismatch
  }
  check_range(
    0,
    if family == 2 {
      ipv4_address_size()
    } else {
      ipv6_address_size()
    },
    buffer.length(),
  )
  let port = (buffer[2].to_int() << 8) | buffer[3].to_int()
  if family == 2 {
    let ip = (buffer[4].to_uint() << 24) |
      (buffer[5].to_uint() << 16) |
      (buffer[6].to_uint() << 8) |
      buffer[7].to_uint()
    @socket.Addr::new(ip, port)
  } else {
    let offset = ipv6_bytes_offset()
    let segments = Array::makei(8, index => {
      ((buffer[offset + index * 2].to_int() << 8) |
      buffer[offset + index * 2 + 1].to_int()).to_string(radix=16)
    })
    let scope = buffer_word(buffer, 24, 4).to_int().reinterpret_as_uint()
    let scope = if scope == 0U { "" } else { "%\{scope}" }
    @socket.Addr::parse("[\{segments.join(":")}\{scope}]:\{port}") catch {
      @socket.InvalidAddr => raise @vm.TypeMismatch
      error => raise @vm.LinkErrorDetail("invalid socket address: \{error}")
    }
  }
}

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
fn Host::socket_address_import(
  _self : Host,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  match name {
    "socket/ipv4_addr_size" => [I32(ipv4_address_size())]
    "socket/ipv6_addr_size" => [I32(ipv6_address_size())]
    "socket/addr_get_ipv6_bytes_offset" => [I32(ipv6_bytes_offset())]
    "socket/init_ip_addr" | "socket/init_ipv6_addr" => {
      let buffer = Bytes::make(
        if name == "socket/init_ip_addr" {
          ipv4_address_size()
        } else {
          ipv6_address_size()
        },
        0,
      )
      if name == "socket/init_ip_addr" {
        init_ipv4_address(
          buffer,
          i32(args[1]).reinterpret_as_uint(),
          i32(args[2]),
        )
      } else {
        init_ipv6_address(
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
      let address = decode_address(bytes)
      guard address.is_ipv6() && i32(args[3]) == 16 else {
        raise @vm.TypeMismatch
      }
      let offset = ipv6_bytes_offset()
      guest_memory(caller).init_data_at(
        i32(args[1]).reinterpret_as_uint().to_int64(),
        bytes[offset:offset + 16].to_owned(),
      )
      []
    }
    _ => {
      let bytes = guest_bytes(caller, i32(args[0]), i32(args[1]))
      let address = decode_address(bytes)
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
          buffer_word(bytes.to_fixedarray(), 24, 4).to_int()
        }
        "socket/addr_is_ipv6_wildcard" => {
          guard address.is_ipv6() else { raise @vm.TypeMismatch }
          let offset = ipv6_bytes_offset()
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
