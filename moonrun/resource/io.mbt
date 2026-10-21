///|
pub fn Resource::prepare_read(
  self : Resource,
  length : Int32,
  position : Int64,
  flags~ : Int32 = 0,
) -> Task raise {
  match self.owner {
    Pipe(_, true) if position != -1L =>
      raise @sys.OSError(
        if @sys.platform is Windows {
          87
        } else {
          29
        },
        context="pipe read position",
      )
    Pipe(_, false) | Watcher(_) =>
      raise @sys.OSError(@sys.bad_fd_errno, context="read direction")
    File(file) => return Task(file.prepare_read(length, position))
    _ => ()
  }
  Task(
    @sys.read_job(
      self.native(),
      length,
      position,
      socket=self.owner is Socket(_),
      flags~,
    ),
  )
}

///|
pub fn Resource::prepare_write(
  self : Resource,
  data : Bytes,
  position : Int64,
  flags~ : Int32 = 0,
) -> Task raise {
  match self.owner {
    Pipe(_, false) if position != -1L =>
      raise @sys.OSError(
        if @sys.platform is Windows {
          87
        } else {
          29
        },
        context="pipe write position",
      )
    Pipe(_, true) | Watcher(_) =>
      raise @sys.OSError(@sys.bad_fd_errno, context="write direction")
    File(_) if self.append && position >= 0L =>
      raise @sys.OSError(
        if @sys.platform is Windows {
          87
        } else {
          22
        },
        context="positioned append write",
      )
    File(file) => return Task(file.prepare_write(data, position))
    _ => ()
  }
  Task(
    @sys.write_job(
      self.native(),
      data,
      position,
      socket=self.owner is Socket(_),
      flags~,
    ),
  )
}

///|
pub fn Resource::read_job(
  self : Resource,
  length : Int32,
  position : Int64,
  flags~ : Int32 = 0,
) -> JobResult raise {
  self.prepare_read(length, position, flags~).run()
}

///|
pub fn Resource::write_job(
  self : Resource,
  data : Bytes,
  position : Int64,
  flags~ : Int32 = 0,
) -> JobResult raise {
  self.prepare_write(data, position, flags~).run()
}
