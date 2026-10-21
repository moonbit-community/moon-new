///|
fn socket_option_signature(name : String) -> @wasm.FuncType? {
  let (params, results) : (
    ReadOnlyArray[@wasm.ValueType],
    ReadOnlyArray[@wasm.ValueType],
  ) = match name {
    "socket/join_multicast_group" => ([I64, I32, I32, I32, I32], [I32])
    "socket/join_multicast_group_v6" => ([I64, I32, I32, I32], [I32])
    "socket/set_multicast_interface"
    | "socket/set_multicast_ttl"
    | "socket/set_multicast_loopback" => ([I64, I32, I32], [I32])
    "socket/set_multicast_interface_v6" => ([I64, I32], [I32])
    "socket/if_nametoindex" => ([I32, I32], [I32])
    "socket/if_indextoname" => ([I32], [I64])
    "socket/find_ipv6_test_interface" => ([], [I32])
    _ => return None
  }
  Some({ params, results, })
}

///|
fn Context::socket_option_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.async_host
  if name == "socket/find_ipv6_test_interface" {
    return [I32(@sys.find_ipv6_interface().reinterpret_as_int())]
  }
  if name == "socket/if_nametoindex" || name == "socket/if_indextoname" {
    let text = if name == "socket/if_nametoindex" {
      guest_string(caller, i32(args[0]), i32(args[1]))
    } else {
      ""
    }
    if text.contains_char('\u0000') {
      host.async_errno = if @sys.platform is Windows { 87 } else { 22 }
      return [I32(0)]
    }
    let fd = @sys.make_udp_socket(4, false)
    if @sys.socket_invalid(fd) {
      host.async_errno = @sys.get_errno()
      return if name == "socket/if_nametoindex" {
        [I32(0)]
      } else {
        [I64(self.runtime.handles.null_handle)]
      }
    }
    defer @sys.close_socket(fd)
    if name == "socket/if_nametoindex" {
      let text = if @sys.platform is Windows {
        @utf16.encode(text, endianness=Little, bom=false) + b"\x00\x00"
      } else {
        // Match OsString: Bytes have a trailing NUL outside their length.
        @utf8.encode(text)
      }
      let index = @sys.interface_index(fd, text)
      if index == 0U {
        host.async_errno = @sys.get_errno()
      }
      [I32(index.reinterpret_as_int())]
    } else {
      let data = @sys.interface_name(fd, i32(args[0]).reinterpret_as_uint())
      if data.is_empty() {
        host.async_errno = @sys.get_errno()
        return [I64(self.runtime.handles.null_handle)]
      }
      let handle = self.runtime.handles.allocate()
      host.buffers[handle] = data.to_fixedarray()
      [I64(handle)]
    }
  } else {
    guard self.socket(args[0]) is Some(fd) else { return [I32(-1)] }
    let result = match name {
      "socket/set_multicast_interface_v6" =>
        @sys.set_multicast_interface_v6(
          fd.native(),
          i32(args[1]).reinterpret_as_uint(),
        )
      "socket/set_multicast_ttl" =>
        @sys.set_multicast_ttl(fd.native(), i32(args[1]), i32(args[2]))
      "socket/set_multicast_loopback" =>
        @sys.set_multicast_loopback(
          fd.native(),
          i32(args[1]) != 0,
          i32(args[2]),
        )
      "socket/join_multicast_group" => {
        let group = guest_bytes(caller, i32(args[1]), i32(args[3]))
        let local_address = guest_bytes(caller, i32(args[2]), i32(args[4]))
        guard !@sys.decode_address(group).is_ipv6() &&
          !@sys.decode_address(local_address).is_ipv6() else {
          raise @vm.TypeMismatch
        }
        @sys.join_multicast(fd.native(), group, local_address)
      }
      "socket/join_multicast_group_v6" => {
        let group = guest_bytes(caller, i32(args[1]), i32(args[3]))
        guard @sys.decode_address(group).is_ipv6() else {
          raise @vm.TypeMismatch
        }
        @sys.join_multicast_v6(
          fd.native(),
          group,
          i32(args[2]).reinterpret_as_uint(),
        )
      }
      "socket/set_multicast_interface" => {
        let address = guest_bytes(caller, i32(args[1]), i32(args[2]))
        guard !@sys.decode_address(address).is_ipv6() else {
          raise @vm.TypeMismatch
        }
        @sys.set_multicast_interface(fd.native(), address)
      }
      _ => raise @vm.UnknownImport("moonbitlang/async", name)
    }
    self.socket_status(result)
  }
}
