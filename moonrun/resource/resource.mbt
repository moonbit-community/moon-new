///|
pub(all) enum ResourceKind {
  Pipe(@raw_fd.RawFd, Bool)
  File(@fs.File)
  Standard(Int32, @types.Fd)
  Socket(Socket)
  Watcher(Watcher)
}

///|
// Jobs retain the OS resource independently of the guest handle. Closing a
// guest handle must not close an fd still in use by a submitted native job.
pub(all) struct Resource {
  owner : ResourceKind
  priv mut references : Int32
  read_lock : @async.Mutex
  write_lock : @async.Mutex
  cursor_lock : @async.Mutex
  mut cursor : Int64
  append : Bool
  guest_async : Bool
  mut path : String?
}

///|
pub fn Resource::Resource(
  owner : ResourceKind,
  append~ : Bool = false,
  guest_async~ : Bool = true,
  path? : String,
) -> Resource {
  {
    owner,
    references: 1,
    read_lock: @async.Mutex(),
    write_lock: @async.Mutex(),
    cursor_lock: @async.Mutex(),
    cursor: 0L,
    append,
    guest_async,
    path,
  }
}

///|
pub fn Resource::native(self : Resource) -> @types.Fd {
  match self.owner {
    Pipe(pipe, _) => pipe.fd
    File(file) => file.fd()
    Standard(_, fd) => fd
    Socket(socket) => socket.fd
    Watcher(watcher) => watcher.fd
  }
}

///|
pub fn Resource::retain(self : Resource) -> Unit {
  self.references += 1
}

///|
pub fn Resource::release(self : Resource) -> Unit {
  self.references -= 1
  if self.references == 0 {
    match self.owner {
      Pipe(pipe, _) => pipe.close()
      File(file) => file.close()
      Standard(_, _) => ()
      Socket(socket) => socket.close()
      Watcher(watcher) => {
        ignore(@sys.close_guest_pipe(watcher.fd))
        watcher.files.clear()
      }
    }
  }
}
