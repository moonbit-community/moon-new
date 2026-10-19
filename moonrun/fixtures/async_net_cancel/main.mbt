///|
async fn main {
  let server = @socket.TcpServer(@socket.Addr::new(0x7F000001U, 0))
  defer server.close()
  @stdio.stdout.write("\{server.addr}\n")
  let (connection, _) = server.accept()
  connection.close()
  raise Failure("unexpected connection")
}
