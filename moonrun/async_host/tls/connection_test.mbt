///|
fn fixture(name : String) -> String {
  @env.current_dir().unwrap_or(".") + "/async_host/tls/test_keys/" + name
}

///|
fn configured_server(root~ : Bool = false) -> @tls.Connection raise {
  let server = @tls.Connection()
  errdefer server.close()
  let result = if @sys.platform is Windows {
    server.server_pfx(
      @sys.read_file(
        fixture(if root { "valid_root_cert.pfx" } else { "cert.pfx" }),
      ),
    )
  } else {
    server.server_files(
      fixture(if root { "valid_root_key.pem" } else { "key.pem" }),
      1,
      fixture(if root { "valid_root_cert.pem" } else { "cert.pem" }),
      1,
    )
  }
  assert_eq(result, 0, msg=server.take_error())
  server
}

///|
fn drop_prefix(input : Array[Byte], count : Int32) -> Unit {
  input[count:].blit_to(input)
  input.truncate(input.length() - count)
}

///|
fn transfer(
  connection : @tls.Connection,
  kind : Int32,
  input : Array[Byte],
  peer : Array[Byte],
  size : Int32,
) -> Int32 {
  let output = FixedArray::make(size, b'\x00')
  let status = connection.step(kind, FixedArray::from_array(input), output, [])
  let read = connection.info(0)
  drop_prefix(input, read)
  peer.push_iter(output[:connection.info(1)].iter())
  status
}

///|
fn handshake(
  client : @tls.Connection,
  server : @tls.Connection,
  size~ : Int32 = 7,
) -> Bool raise {
  let c : Array[Byte] = []
  let s : Array[Byte] = []
  let mut client_ready = false
  let mut server_ready = false
  for _ in 0..<10000 {
    if !client_ready {
      let result = transfer(client, 0, c, s, size)
      if result == 3 {
        return false
      }
      client_ready = result == 0
    }
    if !server_ready {
      let result = transfer(server, 1, s, c, size)
      if result == 3 {
        return false
      }
      server_ready = result == 0
    }
    if client_ready && server_ready {
      return true
    }
  }
  fail(
    "TLS handshake made no progress: \{client.take_error()}, \{server.take_error()}",
  )
}

///|
test "fragmented TLS handshake, plaintext, certificates, bindings and close_notify" {
  let server = configured_server()
  defer server.close()
  let client = @tls.Connection()
  defer client.close()
  assert_eq(client.client("localhost", true, 0), 0, msg=client.take_error())
  assert_true(handshake(client, server))
  assert_eq(client.data(1), server.data(1))
  assert_true(client.data(1) is Some(bytes) && bytes.length() > 0)
  assert_eq(client.data(2), server.data(2))
  assert_true(client.data(0) is Some(bytes) && bytes.length() > 0)
  assert_eq(server.data(0), Some(b""))
  let input : Array[Byte] = []
  let encrypted : Array[Byte] = []
  let message = b"hello encrypted world"
  let mut offset = 0
  for _ in 0..<1000 {
    let output = FixedArray::make(
      if @sys.platform is Windows {
        64
      } else {
        3
      },
      b'\x00',
    )
    let result = client.step(
      3,
      [],
      output,
      message[offset:].to_owned().to_fixedarray(),
    )
    encrypted.push_iter(output[:client.info(1)].iter())
    if result >= 0 {
      offset += result
    } else {
      assert_eq(result, -3)
    }
    if offset == message.length() {
      break
    }
  }
  assert_eq(offset, message.length())
  let plain : Array[Byte] = []
  for byte in encrypted {
    input.push(byte)
    let output = FixedArray::make(4, b'\x00')
    let result = server.step(2, FixedArray::from_array(input), [], output)
    drop_prefix(input, server.info(0))
    if result > 0 {
      plain.push_iter(output[:result].iter())
    } else {
      assert_true(result is (-3 | 0))
    }
  }
  for _ in 0..<message.length() {
    let output = FixedArray::make(4, b'\x00')
    let result = server.step(2, FixedArray::from_array(input), [], output)
    drop_prefix(input, server.info(0))
    if result > 0 {
      plain.push_iter(output[:result].iter())
    } else {
      break
    }
  }
  assert_eq(Bytes::from_array(plain), message)
  assert_eq(client.info(4), 0)
  assert_eq(client.step(3, [], [], b"closed".to_fixedarray()), -2)
  let notify : Array[Byte] = []
  let c : Array[Byte] = []
  for _ in 0..<1000 {
    if transfer(client, 0, c, notify, 2) == 0 {
      break
    }
  }
  let output = FixedArray::make(10, b'\x00')
  assert_eq(server.step(2, FixedArray::from_array(notify), [], output), -2)
}

///|
test "custom TLS roots verify hostnames and reject untrusted certificates" {
  let pem = @utf8.decode_lossy(@sys.read_file(fixture("valid_root_cert.pem")))
  let encoded = pem
    .split("-----BEGIN CERTIFICATE-----")
    .nth(1)
    .unwrap()
    .split("-----END CERTIFICATE-----")
    .nth(0)
    .unwrap()
    .to_owned()
    .replace_all(old="\n", new="")
    .replace_all(old="\r", new="")
  let root = @base64.decode(encoded)
  for host in ["whatever", "wrong.example"] {
    let server = configured_server(root=true)
    defer server.close()
    let client = @tls.Connection()
    defer client.close()
    assert_eq(client.add_root(root), 0)
    assert_eq(client.client(host, true, 2), 0, msg=client.take_error())
    assert_eq(handshake(client, server, size=97), host == "whatever")
  }
  let server = configured_server()
  defer server.close()
  let client = @tls.Connection()
  defer client.close()
  assert_eq(client.client("localhost", true, 2), 0)
  assert_false(handshake(client, server, size=97))
  assert_true(client.take_error() != "unknown TLS error")
}

///|
test "TLS configuration failures keep the handle reusable" {
  let connection = @tls.Connection()
  defer connection.close()
  assert_eq(connection.server_pfx(b"invalid"), -1)
  assert_true(connection.take_error() != "unknown TLS error")
  assert_eq(connection.client("invalid\u0000host", false, 0), -1)
  assert_true(connection.take_error().contains("hostname"))
  assert_eq(connection.client("localhost", false, 0), 0)
  assert_eq(connection.step(2, [], [], FixedArray::make(1, b'\x00')), -4)
}

///|
test "malformed root certificates release partial TLS setup" {
  for _ in 0..<10 {
    let connection = @tls.Connection()
    defer connection.close()
    assert_eq(connection.add_root(b"invalid DER"), 0)
    assert_eq(connection.client("localhost", true, 2), -1)
    assert_true(connection.take_error().contains("root certificate"))
  }
}
