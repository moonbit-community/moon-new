///|
extern "c" fn untrusted_authorizer() -> @ffi.Sqlite3Authorizer = "moonrun_sqlite_authorizer"

///|
// Match the original host: accept only access-mode flags, always serialize.
fn normalize_open_flags(flags : Int32) -> Int32 {
  (flags & 7) | 0x10000
}

///|
fn database_filename(
  filesystem : @filesystem.HostFs,
  filename : Bytes,
  flags : Int32,
) -> Bytes? raise {
  guard !filename.iter().any(byte => byte == b'\x00') else { raise Fault }
  let path = @utf8.decode(filename) catch { _ => raise Fault }
  if path == ":memory:" {
    return Some(filename)
  }
  if path.is_empty() {
    return None
  }
  let resolved = filesystem.resolve(path)
  let parent = @path.Path(resolved).dirname().to_string()
  try {
    filesystem.authorize_path(resolved)
    filesystem.authorize_path(parent)
    if (flags & 6) != 0 {
      filesystem.authorize_path(parent, read=false, write=true)
    }
  } catch {
    @sys.OSError(_) => return None
    error => raise error
  }
  Some(@utf8.encode(resolved))
}

///|
fn install_authorizer(database : @ffi.Sqlite3) -> Int32 {
  @ffi.sqlite3_set_authorizer(database, authorizer=untrusted_authorizer())
}
