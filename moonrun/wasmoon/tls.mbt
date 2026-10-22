///|
fn tls_signature(name : String) -> @wasm.FuncType? {
  let (params, results) : (
    ReadOnlyArray[@wasm.ValueType],
    ReadOnlyArray[@wasm.ValueType],
  ) = match name {
    "tls/connection/new" | "tls/error/take_global" => ([], [I64])
    "tls/connection/set_client" => ([I64, I32, I32, I32, I32], [I32])
    "tls/connection/add_root_certificate" | "tls/connection/set_server_pfx" =>
      ([I64, I32, I32], [I32])
    "tls/connection/set_server_files" =>
      ([I64, I32, I32, I32, I32, I32, I32], [I32])
    "tls/connection/free" => ([I64], [])
    "tls/connection/take_error"
    | "tls/connection/peer_certificate"
    | "tls/connection/unique_channel_binding"
    | "tls/connection/server_endpoint_channel_binding" => ([I64], [I64])
    "tls/connection/bytes_read"
    | "tls/connection/bytes_to_write"
    | "tls/connection/wants_read"
    | "tls/connection/wants_write"
    | "tls/connection/shutdown" => ([I64], [I32])
    "tls/connection/connect" | "tls/connection/accept" =>
      ([I64, I32, I32, I32, I32, I32, I32], [I32])
    "tls/connection/read_plain" | "tls/connection/write_plain" =>
      ([I64, I32, I32, I32, I32, I32, I32, I32, I32, I32], [I32])
    _ => return None
  }
  Some({ params, results, })
}

///|
fn Context::tls_buffer(self : Context, bytes : Bytes) -> Int64 {
  let handle = self.runtime.handles.allocate()
  self.runtime.async_host.buffers[handle] = bytes.to_fixedarray()
  handle
}

///|
fn tls_guest_range(
  memory : @vm.Memory,
  args : Array[@wasm.Value],
  index : Int32,
) -> (Int64, Int32) raise {
  let start = i32(args[index]).reinterpret_as_uint().to_int64() +
    i32(args[index + 1]).reinterpret_as_uint().to_int64()
  let length = i32(args[index + 2])
  guard length >= 0 && start + length.to_int64() <= memory.byte_len() else {
    raise @sys.Bounds
  }
  (start, length)
}

///|
fn tls_overlaps(first : (Int64, Int32), second : (Int64, Int32)) -> Bool {
  first.0 < second.0 + second.1.to_int64() &&
  second.0 < first.0 + first.1.to_int64()
}

///|
fn Context::tls_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.async_host
  if name == "tls/connection/new" {
    let handle = self.runtime.handles.allocate()
    host.tls_connections[handle] = @tls.Connection()
    return [I64(handle)]
  }
  if name == "tls/error/take_global" {
    return [I64(self.tls_buffer(@sys.os_path("unknown TLS error")))]
  }
  let handle = i64(args[0])
  if name == "tls/connection/free" {
    if handle != self.runtime.handles.null_handle {
      guard host.tls_connections.get(handle) is Some(connection) else {
        raise @sys.Operation("Badf")
      }
      host.tls_connections.remove(handle)
      connection.close()
    }
    return []
  }
  guard host.tls_connections.get(handle) is Some(connection) else {
    raise @sys.Operation("Badf")
  }
  match name {
    "tls/connection/set_client" =>
      [
        I32(
          connection.client(
            guest_string(caller, i32(args[1]), i32(args[2])),
            i32(args[3]) != 0,
            i32(args[4]),
          ),
        ),
      ]
    "tls/connection/add_root_certificate" =>
      [
        I32(
          connection.add_root(guest_bytes(caller, i32(args[1]), i32(args[2]))),
        ),
      ]
    "tls/connection/set_server_pfx" =>
      [
        I32(
          connection.server_pfx(guest_bytes(caller, i32(args[1]), i32(args[2]))),
        ),
      ]
    "tls/connection/set_server_files" => {
      let key_type = i32(args[3])
      let cert_type = i32(args[6])
      guard key_type is (1 | 2) && cert_type is (1 | 2) else {
        raise @sys.Invalid
      }
      let fs = self.runtime.filesystem
      let key = fs.resolve(guest_string(caller, i32(args[1]), i32(args[2])))
      let cert = fs.resolve(guest_string(caller, i32(args[4]), i32(args[5])))
      try {
        fs.authorize_path(key)
        fs.authorize_path(cert)
      } catch {
        error =>
          return [
            I32(
              connection.set_error(
                "failed to access TLS certificate or private key file: \{error}",
              ),
            ),
          ]
      }
      [I32(connection.server_files(key, key_type, cert, cert_type))]
    }
    "tls/connection/take_error" =>
      [I64(self.tls_buffer(@sys.os_path(connection.take_error())))]
    "tls/connection/peer_certificate"
    | "tls/connection/unique_channel_binding"
    | "tls/connection/server_endpoint_channel_binding" => {
      let kind = match name {
        "tls/connection/peer_certificate" => 0
        "tls/connection/unique_channel_binding" => 1
        _ => 2
      }
      [
        I64(
          connection
          .data(kind)
          .map(bytes => self.tls_buffer(bytes))
          .unwrap_or(self.runtime.handles.null_handle),
        ),
      ]
    }
    "tls/connection/bytes_read"
    | "tls/connection/bytes_to_write"
    | "tls/connection/wants_read"
    | "tls/connection/wants_write"
    | "tls/connection/shutdown" => {
      let kind = match name {
        "tls/connection/bytes_read" => 0
        "tls/connection/bytes_to_write" => 1
        "tls/connection/wants_read" => 2
        "tls/connection/wants_write" => 3
        _ => 4
      }
      [I32(connection.info(kind))]
    }
    _ => {
      let kind = match name {
        "tls/connection/connect" => 0
        "tls/connection/accept" => 1
        "tls/connection/read_plain" => 2
        "tls/connection/write_plain" => 3
        _ => raise @vm.UnknownImport("moonbitlang/async", name)
      }
      let memory = guest_memory(caller)
      let input = tls_guest_range(memory, args, 1)
      let output = tls_guest_range(memory, args, 4)
      let plain = if kind >= 2 {
        tls_guest_range(memory, args, 7)
      } else {
        (0L, 0)
      }
      guard !tls_overlaps(input, output) &&
        !tls_overlaps(input, plain) &&
        !tls_overlaps(output, plain) else {
        raise @sys.Bounds
      }
      let input_bytes = memory
        .read_bytes(input.0.to_int(), input.1)
        .to_fixedarray()
      let output_bytes = FixedArray::make(output.1, b'\x00')
      let plain_bytes = if kind == 3 {
        memory.read_bytes(plain.0.to_int(), plain.1).to_fixedarray()
      } else {
        FixedArray::make(plain.1, b'\x00')
      }
      let result = connection.step(kind, input_bytes, output_bytes, plain_bytes)
      let written = connection.info(1)
      if written > 0 {
        memory.init_data_at(output.0, Bytes::from_array(output_bytes[:written]))
      }
      if kind == 2 && result > 0 {
        memory.init_data_at(plain.0, Bytes::from_array(plain_bytes[:result]))
      }
      [I32(result)]
    }
  }
}
