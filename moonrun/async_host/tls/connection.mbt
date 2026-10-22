///|
// Pending configuration is kept until setup succeeds, as in Rust TlsHandle.
// Native sessions own their TLS state, never the guest transport or memory.
pub struct Connection {
  priv roots : Array[Bytes]
  priv mut session : Session?
  priv mut error : String?
}

///|
#external
type Session

///|
extern "C" fn Session::new() -> Session = "moonrun_tls_new"

///|
extern "C" fn Session::close(self : Session) -> Unit = "moonrun_tls_free"

///|
#borrow(host)
extern "C" fn Session::client(
  self : Session,
  host : Bytes,
  sni : Bool,
  trust : Int32,
) -> Int32 = "moonrun_tls_client"

///|
#borrow(root)
extern "C" fn Session::add_root(
  self : Session,
  root : Bytes,
  length : Int32,
) -> Int32 = "moonrun_tls_add_root"

///|
#borrow(key, cert)
extern "C" fn Session::server_files(
  self : Session,
  key : Bytes,
  key_type : Int32,
  cert : Bytes,
  cert_type : Int32,
) -> Int32 = "moonrun_tls_server_files"

///|
#borrow(pfx)
extern "C" fn Session::server_pfx(
  self : Session,
  pfx : Bytes,
  length : Int32,
) -> Int32 = "moonrun_tls_server_pfx"

///|
#borrow(input, output, plain)
extern "C" fn Session::step(
  self : Session,
  kind : Int32,
  input : FixedArray[Byte],
  input_length : Int32,
  output : FixedArray[Byte],
  output_length : Int32,
  plain : FixedArray[Byte],
  plain_length : Int32,
) -> Int32 = "moonrun_tls_step"

///|
extern "C" fn Session::info(self : Session, kind : Int32) -> Int32 = "moonrun_tls_info"

///|
extern "C" fn Session::error(self : Session) -> Bytes = "moonrun_tls_error"

///|
extern "C" fn Session::blob_length(self : Session, kind : Int32) -> Int32 = "moonrun_tls_blob_length"

///|
#borrow(output)
extern "C" fn Session::blob_copy(
  self : Session,
  output : FixedArray[Byte],
  length : Int32,
) -> Unit = "moonrun_tls_blob_copy"

///|
pub fn Connection::Connection() -> Connection {
  { roots: [], session: None, error: None, }
}

///|
pub fn Connection::close(self : Connection) -> Unit {
  if self.session is Some(session) {
    session.close()
    self.session = None
  }
}

///|
pub fn Connection::set_error(self : Connection, error : String) -> Int32 {
  self.error = Some(error)
  -1
}

///|
pub fn Connection::take_error(self : Connection) -> String {
  let error = self.error
  self.error = None
  error.unwrap_or_else(() => {
    match self.session {
      Some(session) => @utf8.decode_lossy(session.error())
      None => "unknown TLS error"
    }
  })
}

///|
fn Connection::pending(self : Connection) -> Unit raise @sys.HostError {
  guard self.session is None else { raise @sys.Invalid }
}

///|
pub fn Connection::add_root(self : Connection, root : Bytes) -> Int32 raise {
  self.pending()
  self.error = None
  self.roots.push(root)
  0
}

///|
fn Connection::configure(
  self : Connection,
  setup : (Session) -> Int32,
) -> Int32 raise {
  self.pending()
  let session = Session::new()
  if setup(session) < 0 {
    let error = @utf8.decode_lossy(session.error())
    session.close()
    return self.set_error(error)
  }
  self.error = None
  self.session = Some(session)
  0
}

///|
pub fn Connection::client(
  self : Connection,
  host : String,
  sni : Bool,
  trust : Int32,
) -> Int32 raise {
  guard trust >= 0 && trust <= 2 else { raise @sys.Invalid }
  self.pending()
  if host.contains_char('\u0000') {
    return self.set_error("invalid TLS hostname: embedded NUL")
  }
  let host = @sys.os_path(host)
  if trust != 2 && !self.roots.is_empty() {
    return self.set_error("TLS root certificates require custom root trust")
  }
  self.configure(session => {
    if session.client(host, sni, trust) < 0 {
      return -1
    }
    for root in self.roots {
      if session.add_root(root, root.length()) < 0 {
        return -1
      }
    }
    0
  })
}

///|
pub fn Connection::server_files(
  self : Connection,
  key : String,
  key_type : Int32,
  cert : String,
  cert_type : Int32,
) -> Int32 raise {
  guard key_type is (1 | 2) && cert_type is (1 | 2) else { raise @sys.Invalid }
  self.pending()
  if !self.roots.is_empty() {
    return self.set_error(
      "TLS root certificates require client custom root trust",
    )
  }
  if key.contains_char('\u0000') || cert.contains_char('\u0000') {
    return self.set_error("invalid TLS certificate path: embedded NUL")
  }
  let key = @sys.os_path(key)
  let cert = @sys.os_path(cert)
  self.configure(session => session.server_files(key, key_type, cert, cert_type))
}

///|
pub fn Connection::server_pfx(self : Connection, pfx : Bytes) -> Int32 raise {
  self.pending()
  if !self.roots.is_empty() {
    return self.set_error(
      "TLS root certificates require client custom root trust",
    )
  }
  self.configure(session => session.server_pfx(pfx, pfx.length()))
}

///|
pub fn Connection::step(
  self : Connection,
  kind : Int32,
  input : FixedArray[Byte],
  output : FixedArray[Byte],
  plain : FixedArray[Byte],
) -> Int32 {
  match self.session {
    Some(session) =>
      session.step(
        kind,
        input,
        input.length(),
        output,
        output.length(),
        plain,
        plain.length(),
      )
    None => {
      ignore(self.set_error("TLS handle is not configured"))
      if kind <= 1 {
        3
      } else {
        -1
      }
    }
  }
}

///|
pub fn Connection::info(self : Connection, kind : Int32) -> Int32 {
  match self.session {
    Some(session) => session.info(kind)
    None => {
      ignore(self.set_error("TLS handle is not configured"))
      if kind == 4 {
        -1
      } else {
        0
      }
    }
  }
}

///|
pub fn Connection::data(self : Connection, kind : Int32) -> Bytes? {
  guard self.session is Some(session) else {
    ignore(self.set_error("TLS handle is not configured"))
    return None
  }
  let length = session.blob_length(kind)
  if length < 0 {
    return None
  }
  let output = FixedArray::make(length, b'\x00')
  session.blob_copy(output, length)
  Some(Bytes::from_array(output))
}
