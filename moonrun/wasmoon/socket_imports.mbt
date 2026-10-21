///|
fn Context::socket(
  self : Context,
  value : @wasm.Value,
) -> @resource.Resource? raise {
  match self.runtime.async_host.fds.get(i64(value)) {
    Some(fd) if fd.owner is @resource.Socket(_) => Some(fd)
    _ => {
      self.runtime.async_host.async_errno = @sys.bad_fd_errno
      None
    }
  }
}

///|
fn Context::socket_status(self : Context, result : Int32) -> Array[@wasm.Value] {
  if result < 0 {
    self.runtime.async_host.async_errno = @sys.get_errno()
  }
  [I32(result)]
}

///|
fn Context::socket_bind_job(
  self : Context,
  caller : @vm.Caller,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  guard self.socket(args[0]) is Some(fd) else { raise @vm.TypeMismatch }
  let address = guest_bytes(caller, i32(args[1]), i32(args[2]))
  ignore(@sys.decode_address(address))
  fd.retain()
  [
    I64(
      self.runtime.async_host.new_job(
        () => self.runtime.network.bind_job(fd, address),
        cleanup=() => fd.release(),
      ),
    ),
  ]
}

///|
fn socket_signature(name : String) -> @wasm.FuncType? {
  let (params, results) : (
    ReadOnlyArray[@wasm.ValueType],
    ReadOnlyArray[@wasm.ValueType],
  ) = match name {
    "thread_pool/make_bind_job" => ([I64, I32, I32], [I64])
    "socket/setup_connected_socket/windows" => ([I64], [I32])
    "socket/setup_accepted_socket/windows" | "socket/connect/windows" =>
      ([I64, I64], [I32])
    "socket/accept/windows" => ([I64, I64, I64], [I32])
    "socket/make_tcp_socket" => ([I32], [I64])
    "socket/make_udp_socket" => ([I32, I32], [I64])
    "socket/listen"
    | "socket/disable_nagle"
    | "socket/allow_reuse_addr"
    | "socket/allow_reuse_port"
    | "socket/getsockerr/unix" => ([I64], [I32])
    "socket/set_ipv6_only" => ([I64, I32], [I32])
    "socket/enable_keepalive" => ([I64, I32, I32, I32], [I32])
    "socket/getsockname"
    | "socket/udp_client_connect"
    | "socket/connect/unix"
    | "socket/bind" => ([I64, I32, I32], [I32])
    "socket/accept/unix" => ([I64, I32, I32], [I64])
    "socket/recvfrom/unix" | "socket/sendto/unix" =>
      ([I64, I32, I32, I32, I32, I32], [I32])
    _ => return None
  }
  Some({ params, results, })
}

///|
fn Context::socket_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.async_host
  if name == "socket/make_tcp_socket" || name == "socket/make_udp_socket" {
    let family = i32(args[0])
    guard family == 4 || family == 6 else {
      host.async_errno = if @sys.platform is Windows { 87 } else { 22 }
      return [I64(self.runtime.handles.invalid_fd)]
    }
    let udp = name == "socket/make_udp_socket"
    let multicast = udp && i32(args[1]) != 0
    return {
      let fd = if udp {
        @sys.make_udp_socket(family, multicast)
      } else {
        @sys.make_tcp_socket(family)
      }
      if @sys.socket_invalid(fd) {
        host.async_errno = @sys.get_errno()
        return [I64(self.runtime.handles.invalid_fd)]
      }
      let resource = @resource.Resource::new_socket(fd)
      let handle = self.runtime.handles.allocate()
      host.fds[handle] = resource
      [I64(handle)]
    }
  }
  guard self.socket(args[0]) is Some(fd) else {
    return if name == "socket/accept/unix" {
      [I64(self.runtime.handles.invalid_fd)]
    } else {
      [I32(-1)]
    }
  }
  try {
    match name {
      "socket/listen" => self.socket_status(@sys.listen_socket(fd.native()))
      "socket/disable_nagle" =>
        self.socket_status(@sys.disable_nagle(fd.native()))
      "socket/allow_reuse_addr" =>
        self.socket_status(@sys.allow_reuse_addr(fd.native()))
      "socket/allow_reuse_port" =>
        self.socket_status(@sys.allow_reuse_port(fd.native()))
      "socket/set_ipv6_only" =>
        self.socket_status(@sys.set_ipv6_only(fd.native(), i32(args[1]) != 0))
      "socket/enable_keepalive" =>
        self.socket_status(
          @sys.enable_keepalive(
            fd.native(),
            i32(args[1]),
            i32(args[2]),
            i32(args[3]),
          ),
        )
      "socket/getsockerr/unix" =>
        self.socket_status(@sys.socket_error(fd.native()))
      "socket/getsockname"
      | "socket/udp_client_connect"
      | "socket/connect/unix"
      | "socket/bind" => {
        let address = guest_bytes(caller, i32(args[1]), i32(args[2]))
        ignore(@sys.decode_address(address))
        let result = if name == "socket/getsockname" {
          @sys.socket_name(fd.native(), address)
        } else {
          try {
            if name == "socket/bind" {
              self.runtime.network.bind(fd, address)
            } else {
              self.runtime.network.connect(fd, address)
            }
            0
          } catch {
            @sys.OSError(code, ..) => {
              host.async_errno = code
              return [I32(-1)]
            }
            error => raise error
          }
        }
        if name == "socket/getsockname" && result >= 0 {
          guest_memory(caller).init_data_at(
            i32(args[1]).reinterpret_as_uint().to_int64(),
            address,
          )
        }
        self.socket_status(result)
      }
      "socket/accept/unix" => {
        let address = guest_bytes(caller, i32(args[1]), i32(args[2]))
        ignore(@sys.decode_address(address))
        let accepted = @sys.accept_socket(
          fd.native(),
          address,
          address.length(),
        )
        if @sys.socket_invalid(accepted) {
          host.async_errno = @sys.get_errno()
          return [I64(self.runtime.handles.invalid_fd)]
        }
        let resource = @resource.Resource::new_socket(accepted)
        let handle = self.runtime.handles.allocate()
        host.fds[handle] = resource
        guest_memory(caller).init_data_at(
          i32(args[1]).reinterpret_as_uint().to_int64(),
          address,
        )
        [I64(handle)]
      }
      "socket/recvfrom/unix" | "socket/sendto/unix" => {
        let receiving = name == "socket/recvfrom/unix"
        let pointer = i32(args[1]).reinterpret_as_uint().to_int64() +
          i32(args[2]).reinterpret_as_uint().to_int64()
        guard pointer <= 0xFFFF_FFFFL else {
          host.async_errno = @sys.fault_errno
          return [I32(-1)]
        }
        let length = i32(args[3])
        let buffer = guest_bytes(caller, pointer.to_int(), length)
        let address = guest_bytes(caller, i32(args[4]), i32(args[5]))
        ignore(@sys.decode_address(address))
        let result = if receiving {
          let buffer = buffer.to_fixedarray()
          let count = @sys.socket_recvfrom(
            fd.native(),
            buffer,
            length,
            0,
            address,
            address.length(),
          )
          if count >= 0 {
            guest_memory(caller).init_data_at(
              pointer,
              Bytes::from_array(buffer[:count]),
            )
            guest_memory(caller).init_data_at(
              i32(args[4]).reinterpret_as_uint().to_int64(),
              address,
            )
          }
          count
        } else {
          self.runtime.network.send_to(fd, buffer, address) catch {
            @sys.OSError(code, ..) => {
              host.async_errno = code
              return [I32(-1)]
            }
            error => raise error
          }
        }
        self.socket_status(result)
      }
      _ => raise @vm.UnknownImport("moonbitlang/async", name)
    }
  } catch {
    @vm.OutOfBoundsMemoryAccess | @sys.Bounds => {
      host.async_errno = @sys.fault_errno
      if name == "socket/accept/unix" {
        [I64(self.runtime.handles.invalid_fd)]
      } else {
        [I32(-1)]
      }
    }
    error => raise error
  }
}

///|
fn Context::windows_socket_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.async_host
  match name {
    "thread_pool/make_bind_job" => self.socket_bind_job(caller, args)
    "socket/setup_connected_socket/windows"
    | "socket/setup_accepted_socket/windows" => {
      guard self.socket(args[0]) is Some(_) else { return [I32(-1)] }
      if name == "socket/setup_accepted_socket/windows" &&
        self.socket(args[1]) is None {
        return [I32(-1)]
      }
      // These adapters use connect/accept, whose socket contexts are already
      // complete. SO_UPDATE_*_CONTEXT is only needed after ConnectEx/AcceptEx.
      [I32(0)]
    }
    "socket/connect/windows" => {
      let handle = i64(args[1])
      guard host.io_results.get(handle) is Some(io) &&
        io.operation is Connect(_) else {
        raise @vm.TypeMismatch
      }
      ignore(
        host.start_io(io, handle, i64(args[0]), fd => {
          self.runtime.network.perform_socket_io(io, fd)
        }),
      )
      // This ABI returns a BOOL, unlike the byte-count read/write APIs.
      [I32(0)]
    }
    "socket/accept/windows" => {
      let handle = i64(args[2])
      let target = i64(args[1])
      guard host.io_results.get(handle) is Some(io) &&
        io.operation is Accept(length) else {
        raise @vm.TypeMismatch
      }
      guard self.socket(args[1]) is Some(placeholder) else { return [I32(0)] }
      guard !host.accepting.contains(target) else {
        host.async_errno = 87
        return [I32(0)]
      }
      host.accepting.add(target)
      placeholder.retain()
      let result : Int32 = {
        errdefer placeholder.release()
        errdefer host.accepting.remove(target) |> ignore
        host.start_io(io, handle, i64(args[0]), fd => {
          guard fd.owner is @resource.Socket(socket) else {
            raise @sys.OSError(@sys.bad_fd_errno, context="accept socket")
          }
          let operation = @sys.network_job(
            4,
            socket.fd,
            Bytes::make(length, 0),
            b"",
            0,
            0,
          )
          @resource.Task(
            operation,
            publish=() => {
              let result = @resource.result(operation)
              if result.ret < 0 {
                return result
              }
              let resource = @resource.Resource::new_socket(operation.take_fd())
              guard host.fds.contains(target) else {
                resource.release()
                raise @sys.OSError(
                  @sys.bad_fd_errno,
                  context="closed accepted socket",
                )
              }
              host.fds[target] = resource
              placeholder.release()
              io.peer = Some(operation.peer())
              result
            },
            cleanup=() => {
              placeholder.release()
              host.accepting.remove(target)
            },
          )
        })
      }
      guard result == -1 && io.pending else {
        placeholder.release()
        host.accepting.remove(target) |> ignore
        return [I32(0)]
      }
      [I32(0)]
    }
    _ => self.socket_import(caller, name, args)
  }
}
