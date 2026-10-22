///|
#warnings("-alert_internal")
async fn main {
  let keys = @env.args()[1]
  let message = Bytes::make(131072, b'x')
  let bindings : Array[Bytes] = []
  @async.with_task_group(group => {
    let (server_input, client_output) = @pipe.pipe()
    let (client_input, server_output) = @pipe.pipe()
    group.spawn_bg(() => {
      defer server_input.close()
      defer server_output.close()
      let server = @tls.Tls::server_from_pair(
        server_input,
        server_output,
        private_key_file=keys + "/key.pem",
        private_key_type=PEM,
        certificate_file=keys + "/cert.pem",
        certificate_type=PEM,
        pfx_file=keys + "/cert.pfx",
      )
      defer server.close()
      bindings.push(server.unique_channel_binding())
      assert_eq(server.read_exactly(message.length()), message)
      server.write(message)
      server.shutdown()
      assert_eq(server.read_all().binary(), b"")
    })
    defer client_input.close()
    defer client_output.close()
    let client = @tls.Tls::client_from_pair(
      client_input,
      client_output,
      host="localhost",
      trust=NoVerification,
    )
    defer client.close()
    bindings.push(client.unique_channel_binding())
    assert_true(
      client.get_peer_certificate() is Some(certificate) &&
      certificate.length() > 0,
    )
    client.write(message)
    assert_eq(client.read_exactly(message.length()), message)
    assert_eq(client.read_all().binary(), b"")
  })
  assert_eq(bindings.length(), 2)
  assert_eq(bindings[0], bindings[1])
  assert_true(bindings[0].length() > 0)
  println("TLS handshake, large transfer, channel binding and shutdown passed")
}
