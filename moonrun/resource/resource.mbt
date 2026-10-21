///|
pub(all) enum ResourceKind {
  Pipe(@sys.Fd, Bool)
  File(@sys.File)
  Standard(Int32, @sys.Fd)
  Socket(Socket)
  Watcher(Watcher)
}

///|
// Jobs retain the OS resource independently of the guest handle. Closing a
// guest handle must not close an fd still in use by a submitted native job.
pub(all) struct Resource {
  owner : ResourceKind
  priv mut references : Int32
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
  { owner, references: 1, append, guest_async, path, }
}

///|
pub fn Resource::native(self : Resource) -> @sys.Fd {
  match self.owner {
    Pipe(pipe, _) => pipe
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
      Pipe(pipe, _) => ignore(@sys.close_guest_pipe(pipe))
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
