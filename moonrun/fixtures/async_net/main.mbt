///|
async fn main {
  let local_address = @socket.Addr::resolve(
    "localhost",
    port=80,
    protocol=OnlyV4,
  )
  assert_false(local_address.is_ipv6())
  assert_eq(local_address.port(), 80)
  @async.with_task_group(group => {
    let server = @socket.TcpServer(@socket.Addr::new(0x7F000001U, 0))
    defer server.close()
    let echo = group.spawn(() => {
      let (connection, _) = server.accept()
      defer connection.close()
      let bytes = connection.read_exactly(6)
      assert_eq(bytes, b"hello\x00")
      connection.write(bytes)
    })
    let client = @socket.Tcp::connect(server.addr)
    defer client.close()
    client.write(b"hello\x00")
    assert_eq(client.read_exactly(6), b"hello\x00")
    echo.wait()
  })
  let server = @socket.UdpServer(@socket.Addr::new(0x7F000001U, 0))
  defer server.close()
  let client = @socket.UdpClient(server.addr)
  defer client.close()
  client.send(b"datagram\x00")
  let bytes = FixedArray::make(32, b'\x00')
  let (count, peer) = server.recvfrom(bytes)
  assert_eq(count, 9)
  assert_eq(Bytes::from_array(bytes[:count]), b"datagram\x00")
  server.sendto(b"reply", peer)
  assert_eq(client.recv(bytes), 5)
  assert_eq(Bytes::from_array(bytes[:5]), b"reply")
  @stdio.stdout.write("async TCP and UDP passed\n")
}
