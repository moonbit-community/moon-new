///|
pub extern "C" fn socket_invalid(fd : Fd) -> Bool = "moonrun_socket_invalid"

///|
pub extern "C" fn prepare_socket(fd : Fd) -> Int32 = "moonrun_socket_prepare"

///|
pub extern "C" fn close_socket(fd : Fd) -> Unit = "moonrun_socket_close"

///|
pub extern "C" fn watch_socket(bus : NativeEventBus, fd : Fd) -> Int32 = "moonrun_event_bus_watch_socket"

///|
#borrow(addr)
pub extern "C" fn bind_socket(fd : Fd, addr : Bytes, length : Int32) -> Int32 = "moonrun_socket_bind"

///|
#borrow(addr)
pub extern "C" fn connect_socket(
  fd : Fd,
  addr : Bytes,
  length : Int32,
) -> Int32 = "moonrun_socket_connect"

///|
#borrow(addr)
pub extern "C" fn accept_socket(fd : Fd, addr : Bytes, length : Int32) -> Fd = "moonrun_socket_accept"

///|
pub extern "C" fn socket_error(fd : Fd) -> Int32 = "moonrun_socket_error"

///|
#borrow(buffer)
pub extern "C" fn socket_read(
  fd : Fd,
  buffer : FixedArray[Byte],
  length : Int32,
  flags : Int32,
) -> Int32 = "moonrun_socket_read"

///|
#borrow(buffer)
pub extern "C" fn socket_write(
  fd : Fd,
  buffer : Bytes,
  length : Int32,
  flags : Int32,
) -> Int32 = "moonrun_socket_write"

///|
pub extern "C" fn make_tcp_socket(family : Int32) -> Fd = "moonrun_native_make_tcp_socket"

///|
pub extern "C" fn make_udp_socket(family : Int32, multicast : Bool) -> Fd = "moonrun_native_make_udp_socket"

///|
pub extern "C" fn listen_socket(fd : Fd) -> Int32 = "moonrun_native_listen"

///|
pub extern "C" fn disable_nagle(fd : Fd) -> Int32 = "moonrun_native_disable_nagle"

///|
pub extern "C" fn allow_reuse_addr(fd : Fd) -> Int32 = "moonrun_native_allow_reuse_addr"

///|
pub extern "C" fn allow_reuse_port(fd : Fd) -> Int32 = "moonrun_native_allow_reuse_port"

///|
pub extern "C" fn set_ipv6_only(fd : Fd, value : Bool) -> Int32 = "moonrun_native_set_ipv6_only"

///|
pub extern "C" fn enable_keepalive(
  fd : Fd,
  idle : Int32,
  count : Int32,
  interval : Int32,
) -> Int32 = "moonrun_native_enable_keepalive"

///|
#borrow(addr)
pub extern "C" fn socket_name(fd : Fd, addr : Bytes) -> Int32 = "moonrun_native_getsockname"

///|
#borrow(buffer, addr)
pub extern "C" fn socket_recvfrom(
  fd : Fd,
  buffer : FixedArray[Byte],
  length : Int32,
  flags : Int32,
  addr : Bytes,
  addr_length : Int32,
) -> Int32 = "moonrun_socket_recvfrom"

///|
#borrow(buffer, addr)
pub extern "C" fn socket_sendto(
  fd : Fd,
  buffer : Bytes,
  length : Int32,
  flags : Int32,
  addr : Bytes,
  addr_length : Int32,
) -> Int32 = "moonrun_socket_sendto"

///|
#borrow(group, local_address)
pub extern "C" fn join_multicast(
  fd : Fd,
  group : Bytes,
  local_address : Bytes,
) -> Int32 = "moonrun_native_join_multicast_group"

///|
#borrow(group)
pub extern "C" fn join_multicast_v6(
  fd : Fd,
  group : Bytes,
  interface : UInt32,
) -> Int32 = "moonrun_native_join_multicast_group_v6"

///|
#borrow(address)
pub extern "C" fn set_multicast_interface(fd : Fd, address : Bytes) -> Int32 = "moonrun_native_set_multicast_interface"

///|
pub extern "C" fn set_multicast_interface_v6(
  fd : Fd,
  interface : UInt32,
) -> Int32 = "moonrun_native_set_multicast_interface_v6"

///|
pub extern "C" fn set_multicast_ttl(
  fd : Fd,
  ttl : Int32,
  family : Int32,
) -> Int32 = "moonrun_native_set_multicast_ttl"

///|
pub extern "C" fn set_multicast_loopback(
  fd : Fd,
  enabled : Bool,
  family : Int32,
) -> Int32 = "moonrun_native_set_multicast_loopback"

///|
#borrow(name)
pub extern "C" fn interface_index(fd : Fd, name : Bytes) -> UInt32 = "moonrun_native_if_nametoindex"

///|
pub extern "C" fn interface_name(fd : Fd, index : UInt32) -> Bytes = "moonrun_interface_name"

///|
pub extern "C" fn find_ipv6_interface() -> UInt32 = "moonrun_native_find_ipv6_test_interface"

///|
pub extern "C" fn ipv4_address_size() -> Int32 = "moonrun_native_ipv4_addr_size"

///|
pub extern "C" fn ipv6_address_size() -> Int32 = "moonrun_native_ipv6_addr_size"

///|
pub extern "C" fn ipv6_bytes_offset() -> Int32 = "moonrun_native_addr_get_ipv6_bytes_offset"

///|
#borrow(buffer)
pub extern "C" fn init_ipv4_address(
  buffer : Bytes,
  ip : UInt32,
  port : Int32,
) -> Unit = "moonrun_native_init_ip_addr"

///|
#borrow(buffer, ip)
pub extern "C" fn init_ipv6_address(
  buffer : Bytes,
  ip : Bytes,
  port : Int32,
  scope : UInt32,
) -> Unit = "moonrun_native_init_ipv6_addr"

///|
pub fn decode_address(bytes : Bytes) -> Addr raise HostError {
  let buffer = bytes.to_fixedarray()
  check_range(0, 2, buffer.length())
  let family = if platform is MacOS {
    buffer[1].to_int()
  } else {
    buffer_word(buffer, 0, 2).to_int()
  }
  guard family == 2 ||
    family ==
    (match platform {
      Linux => 10
      MacOS => 30
      Windows => 23
    }) else {
    raise Invalid
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
    Addr::new(ip, port)
  } else {
    let offset = ipv6_bytes_offset()
    let segments = Array::makei(8, index => {
      ((buffer[offset + index * 2].to_int() << 8) |
      buffer[offset + index * 2 + 1].to_int()).to_string(radix=16)
    })
    let scope = buffer_word(buffer, 24, 4).to_int().reinterpret_as_uint()
    let scope = if scope == 0U { "" } else { "%\{scope}" }
    Addr::parse("[\{segments.join(":")}\{scope}]:\{port}") catch {
      InvalidAddr => raise Invalid
      error => raise Operation("invalid socket address: \{error}")
    }
  }
}

///|
pub extern "C" fn gai_message(code : Int32) -> Bytes = "moonrun_gai_message"
