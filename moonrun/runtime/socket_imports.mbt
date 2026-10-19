///|
extern "C" fn make_tcp_socket(family : Int32) -> @types.Fd = "moonbitlang_async_make_tcp_socket"

///|
extern "C" fn make_udp_socket(family : Int32, multicast : Bool) -> @types.Fd = "moonbitlang_async_make_udp_socket"

///|
extern "C" fn listen_socket(fd : @types.Fd) -> Int32 = "moonbitlang_async_listen"

///|
extern "C" fn disable_nagle(fd : @types.Fd) -> Int32 = "moonbitlang_async_disable_nagle"

///|
extern "C" fn allow_reuse_addr(fd : @types.Fd) -> Int32 = "moonbitlang_async_allow_reuse_addr"

///|
extern "C" fn allow_reuse_port(fd : @types.Fd) -> Int32 = "moonbitlang_async_allow_reuse_port"

///|
extern "C" fn set_ipv6_only(fd : @types.Fd, value : Bool) -> Int32 = "moonbitlang_async_set_ipv6_only"

///|
extern "C" fn enable_keepalive(
  fd : @types.Fd,
  idle : Int32,
  count : Int32,
  interval : Int32,
) -> Int32 = "moonbitlang_async_enable_keepalive"

///|
#borrow(addr)
extern "C" fn socket_name(fd : @types.Fd, addr : Bytes) -> Int32 = "moonbitlang_async_getsockname"

///|
#borrow(buffer, addr)
extern "C" fn socket_recvfrom(
  fd : @types.Fd,
  buffer : FixedArray[Byte],
  length : Int32,
  flags : Int32,
  addr : Bytes,
  addr_length : Int32,
) -> Int32 = "moonrun_socket_recvfrom"

///|
#borrow(buffer, addr)
extern "C" fn socket_sendto(
  fd : @types.Fd,
  buffer : Bytes,
  length : Int32,
  flags : Int32,
  addr : Bytes,
  addr_length : Int32,
) -> Int32 = "moonrun_socket_sendto"

///|
fn Host::socket(
  self : Host,
  value : @wasm.Value,
) -> GuestFd? raise @vm.RuntimeError {
  match self.fds.get(i64(value)) {
    Some(fd) if fd.owner is Socket(_) => Some(fd)
    _ => {
      self.async_errno = bad_fd_errno
      None
    }
  }
}

///|
fn Host::socket_status(self : Host, result : Int32) -> Array[@wasm.Value] {
  if result < 0 {
    self.async_errno = @os_error.get_errno()
  }
  [I32(result)]
}

///|
fn Host::socket_bind_job(
  self : Host,
  caller : @vm.Caller,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  guard self.socket(args[0]) is Some(fd) else { raise @vm.TypeMismatch }
  let address = guest_bytes(caller, i32(args[1]), i32(args[2]))
  ignore(decode_address(address))
  fd.retain()
  self.new_job(
    () => {
      self.authorize_socket(true, address)
      let ret = bind_socket(fd.native(), address, address.length())
      let errno = if ret < 0 { @os_error.get_errno() } else { 0 }
      { ret, errno, data: b"", opened: None, }
    },
    cleanup=() => fd.release(),
  )
}

///|
fn socket_signature(name : String) -> @wasm.FuncType? {
  let (params, results) : (
    ReadOnlyArray[@wasm.ValueType],
    ReadOnlyArray[@wasm.ValueType],
  ) = match name {
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
fn Host::socket_import(
  self : Host,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  if name == "socket/make_tcp_socket" || name == "socket/make_udp_socket" {
    let family = i32(args[0])
    guard family == 4 || family == 6 else {
      self.async_errno = if @async.platform is Windows { 87 } else { 22 }
      return [I64(0L)]
    }
    let udp = name == "socket/make_udp_socket"
    let multicast = udp && i32(args[1]) != 0
    return self.suspend(() => {
      let fd = if udp {
        make_udp_socket(family, multicast)
      } else {
        make_tcp_socket(family)
      }
      if socket_invalid(fd) {
        self.async_errno = @os_error.get_errno()
        return [I64(0L)]
      }
      let resource = self.new_socket(fd)
      let handle = self.next_handle
      self.next_handle += 1L
      self.fds[handle] = resource
      [I64(handle)]
    })
  }
  guard self.socket(args[0]) is Some(fd) else {
    return if name == "socket/accept/unix" { [I64(0L)] } else { [I32(-1)] }
  }
  try {
    match name {
      "socket/listen" => self.socket_status(listen_socket(fd.native()))
      "socket/disable_nagle" => self.socket_status(disable_nagle(fd.native()))
      "socket/allow_reuse_addr" =>
        self.socket_status(allow_reuse_addr(fd.native()))
      "socket/allow_reuse_port" =>
        self.socket_status(allow_reuse_port(fd.native()))
      "socket/set_ipv6_only" =>
        self.socket_status(set_ipv6_only(fd.native(), i32(args[1]) != 0))
      "socket/enable_keepalive" =>
        self.socket_status(
          enable_keepalive(
            fd.native(),
            i32(args[1]),
            i32(args[2]),
            i32(args[3]),
          ),
        )
      "socket/getsockerr/unix" => self.socket_status(socket_error(fd.native()))
      "socket/getsockname"
      | "socket/udp_client_connect"
      | "socket/connect/unix"
      | "socket/bind" => {
        let address = guest_bytes(caller, i32(args[1]), i32(args[2]))
        ignore(decode_address(address))
        self.suspend(() => {
          if name != "socket/getsockname" &&
            !self.socket_allowed(name == "socket/bind", address) {
            self.output(
              2,
              @utf8.encode(
                "Sandbox policy blocked network \{if name == "socket/bind" { "bind" } else { "connect" }}: \{decode_address(address)}\n",
              ),
            )
            self.async_errno = if @async.platform is Windows { 5 } else { 13 }
            return [I32(-1)]
          }
          let result = if name == "socket/getsockname" {
            socket_name(fd.native(), address)
          } else if name == "socket/bind" {
            bind_socket(fd.native(), address, address.length())
          } else {
            connect_socket(fd.native(), address, address.length())
          }
          if name == "socket/getsockname" && result >= 0 {
            guest_memory(caller).init_data_at(
              i32(args[1]).reinterpret_as_uint().to_int64(),
              address,
            )
          }
          self.socket_status(result)
        })
      }
      "socket/accept/unix" => {
        let address = guest_bytes(caller, i32(args[1]), i32(args[2]))
        ignore(decode_address(address))
        self.suspend(() => {
          let accepted = accept_socket(fd.native(), address, address.length())
          if socket_invalid(accepted) {
            self.async_errno = @os_error.get_errno()
            return [I64(0L)]
          }
          let resource = self.new_socket(accepted)
          let handle = self.next_handle
          self.next_handle += 1L
          self.fds[handle] = resource
          guest_memory(caller).init_data_at(
            i32(args[1]).reinterpret_as_uint().to_int64(),
            address,
          )
          [I64(handle)]
        })
      }
      "socket/recvfrom/unix" | "socket/sendto/unix" => {
        let receiving = name == "socket/recvfrom/unix"
        let pointer = i32(args[1]).reinterpret_as_uint().to_int64() +
          i32(args[2]).reinterpret_as_uint().to_int64()
        guard pointer <= 0xFFFF_FFFFL else {
          self.async_errno = fault_errno
          return [I32(-1)]
        }
        let length = i32(args[3])
        let buffer = guest_bytes(caller, pointer.to_int(), length)
        let address = guest_bytes(caller, i32(args[4]), i32(args[5]))
        ignore(decode_address(address))
        self.suspend(() => {
          if !receiving && !self.socket_allowed(false, address) {
            self.output(
              2,
              @utf8.encode(
                "Sandbox policy blocked network connect: \{decode_address(address)}\n",
              ),
            )
            self.async_errno = if @async.platform is Windows { 5 } else { 13 }
            return [I32(-1)]
          }
          let result = if receiving {
            let buffer = buffer.to_fixedarray()
            let count = socket_recvfrom(
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
            socket_sendto(
              fd.native(),
              buffer,
              length,
              0,
              address,
              address.length(),
            )
          }
          self.socket_status(result)
        })
      }
      _ => raise @vm.UnknownImport("moonbitlang/async", name)
    }
  } catch {
    @vm.OutOfBoundsMemoryAccess => {
      self.async_errno = fault_errno
      if name == "socket/accept/unix" {
        [I64(0L)]
      } else {
        [I32(-1)]
      }
    }
    error => raise error
  }
}

///|
async fn Host::perform_socket_io(
  self : Host,
  io : GuestIoResult,
  fd : GuestFd,
) -> JobResult {
  guard fd.owner is Socket(socket) else {
    raise @os_error.OSError(bad_fd_errno, context="socket I/O")
  }
  if io.operation.event() == 1 {
    fd.read_lock.acquire()
  } else {
    fd.write_lock.acquire()
  }
  defer (if io.operation.event() == 1 {
    fd.read_lock.release()
  } else {
    fd.write_lock.release()
  })
  let mut data = b""
  let ret = match io.operation {
    Connect(address) => {
      self.authorize_socket(false, address)
      socket.connect_error = None
      let sequence = socket.write_sequence
      if connect_socket(socket.fd, address, address.length()) < 0 {
        let error = @os_error.OSError(
          @os_error.get_errno(),
          context="socket connect",
        )
        if !error.is_nonblocking_io_error() {
          raise error
        }
        socket.wait_write(sequence)
        if socket.connect_error is Some(error) {
          raise @os_error.OSError(error, context="socket connect")
        }
        let error = socket_error(socket.fd)
        if error < 0 {
          @os_error.check_errno("socket connect status")
        }
        if error > 0 {
          raise @os_error.OSError(error, context="socket connect")
        }
      }
      0
    }
    Receive(address) => {
      let buffer = FixedArray::make(io.length, b'\x00')
      let count = for ;; {
        let sequence = socket.read_sequence
        let count = socket_recvfrom(
          socket.fd,
          buffer,
          io.length,
          io.flags,
          address,
          address.length(),
        )
        if count >= 0 {
          break count
        }
        let error = @os_error.OSError(
          @os_error.get_errno(),
          context="socket receive",
        )
        if error.is_EINTR() {
          continue
        }
        if !error.is_nonblocking_io_error() {
          raise error
        }
        socket.wait_read(sequence)
      }
      data = Bytes::from_array(buffer[:count])
      count
    }
    Send(address) => {
      self.authorize_socket(false, address)
      for ;; {
        let sequence = socket.write_sequence
        let count = socket_sendto(
          socket.fd,
          io.data,
          io.data.length(),
          io.flags,
          address,
          address.length(),
        )
        if count >= 0 {
          break count
        }
        let error = @os_error.OSError(
          @os_error.get_errno(),
          context="socket send",
        )
        if error.is_EINTR() {
          continue
        }
        if !error.is_nonblocking_io_error() {
          raise error
        }
        socket.wait_write(sequence)
      }
    }
    _ => raise @os_error.OSError(87, context="socket I/O operation")
  }
  { ret, errno: 0, data, opened: None, }
}

///|
fn Host::windows_socket_import(
  self : Host,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  match name {
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
      guard self.io_results.get(handle) is Some(io) &&
        io.operation is Connect(_) else {
        raise @vm.TypeMismatch
      }
      ignore(
        self.start_io(io, handle, i64(args[0]), fd => {
          self.perform_socket_io(io, fd)
        }),
      )
      // This ABI returns a BOOL, unlike the byte-count read/write APIs.
      [I32(0)]
    }
    "socket/accept/windows" => {
      let handle = i64(args[2])
      let target = i64(args[1])
      guard self.io_results.get(handle) is Some(io) &&
        io.operation is Accept(length) else {
        raise @vm.TypeMismatch
      }
      guard self.socket(args[1]) is Some(placeholder) else { return [I32(0)] }
      guard !self.accepting.contains(target) else {
        self.async_errno = 87
        return [I32(0)]
      }
      self.accepting.add(target)
      placeholder.retain()
      let result = {
        errdefer placeholder.release()
        errdefer self.accepting.remove(target) |> ignore
        self.start_io(io, handle, i64(args[0]), fd => {
          defer placeholder.release()
          defer self.accepting.remove(target) |> ignore
          guard fd.owner is Socket(socket) else {
            raise @os_error.OSError(bad_fd_errno, context="accept socket")
          }
          fd.read_lock.acquire()
          defer fd.read_lock.release()
          let peer = Bytes::make(length, 0)
          let accepted = for ;; {
            let sequence = socket.read_sequence
            let accepted = accept_socket(socket.fd, peer, length)
            if !socket_invalid(accepted) {
              break accepted
            }
            let error = @os_error.OSError(
              @os_error.get_errno(),
              context="accept socket",
            )
            if error.is_EINTR() {
              continue
            }
            if !error.is_nonblocking_io_error() {
              raise error
            }
            socket.wait_read(sequence)
          }
          let resource = self.new_socket(accepted)
          guard self.fds.contains(target) else {
            resource.release()
            raise @os_error.OSError(
              bad_fd_errno,
              context="closed accepted socket",
            )
          }
          self.fds[target] = resource
          placeholder.release()
          io.peer = Some(peer)
          { ret: 0, errno: 0, data: b"", opened: None, }
        })
      }
      guard result is [I32(-1)] && io.pending else {
        placeholder.release()
        self.accepting.remove(target) |> ignore
        return [I32(0)]
      }
      [I32(0)]
    }
    _ => self.socket_import(caller, name, args)
  }
}
