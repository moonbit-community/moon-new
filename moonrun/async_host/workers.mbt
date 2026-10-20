///|
pub struct Job {
  priv action : async () -> @resource.JobResult
  priv mut cleanup : (() -> Unit)?
  mut result : @resource.JobResult?
  mut running : Bool
  priv mut result_handle : PublishedResult?
  spawn : @process.SpawnOptions?
  sqlite : @sqlite.Job?
  priv mut detached : Bool
}

///|
pub(all) enum PublishedResult {
  OpenedFile(Int64)
  ResolvedAddresses(Int64)
  SpawnedProcess(Int64)
  BorrowedBuffer(Int64)
}

///|
pub fn Job::dispose(self : Job) -> Unit {
  if self.running {
    self.detached = true
    return
  }
  if self.result is Some(result) && result.opened is Some(fd) {
    fd.release()
    result.opened = None
  }
  if self.cleanup is Some(cleanup) {
    self.cleanup = None
    cleanup()
  }
}

///|
pub struct Worker {
  mut task : @async.Task[Unit]?
  mut done : Bool
  completion : @resource.Resource?
  mut detached : Bool
  priv mut completion_owned : Bool
}

///|
pub struct ThreadPool {
  bus : @sys.EventBus
  source : Int64
  read : @types.Fd
  write : @types.Fd
  priv completed : Array[Int32]
  priv mut offset : Int32
  mut closed : Bool
}

///|
pub fn ThreadPool::close(self : ThreadPool) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  if !(@async.platform is Windows) {
    ignore(@sys.close_guest_pipe(self.read))
    ignore(@sys.close_guest_pipe(self.write))
  }
  self.completed.clear()
}

///|
pub fn ThreadPool::notify(
  self : ThreadPool,
  id : Int32,
) -> Unit raise @sys.HostError {
  if self.closed || self.bus.closed {
    return
  }
  if @async.platform is Windows {
    if @sys.post_completion(self.bus.native, self.source, 0L, id) < 0 {
      raise @sys.Operation("failed to post worker completion")
    }
  } else {
    let was_empty = self.offset == self.completed.length()
    self.completed.push(id)
    if was_empty && @sys.signal_completion(self.write) != 1 {
      raise @sys.Operation("failed to signal worker completion")
    }
  }
}

///|
pub fn AsyncHost::new_job(
  self : AsyncHost,
  action : async () -> @resource.JobResult,
  cleanup? : () -> Unit,
  sqlite? : @sqlite.Job,
) -> Int64 {
  let handle = self.handles.allocate()
  self.jobs[handle] = {
    action,
    cleanup,
    result: None,
    running: false,
    result_handle: None,
    spawn: None,
    sqlite,
    detached: false,
  }
  handle
}

///|
pub fn AsyncHost::start_worker(
  self : AsyncHost,
  worker : Worker,
  id : Int32,
  job : Job,
) -> Unit raise @sys.HostError {
  guard !job.running &&
    job.result is None &&
    (worker.completion is Some(_) || (self.pool is Some(pool) && !pool.closed)) else {
    raise @sys.Invalid
  }
  worker.done = false
  job.running = true
  worker.task = Some(
    self.group.spawn(no_wait=true, () => {
      defer {
        job.running = false
        if job.detached {
          job.dispose()
        }
        if worker.detached {
          worker.close()
        }
      }
      let result = @async.handle_cancellation(() => {
        (job.action)() catch {
          @os_error.OSError(code, ..) =>
            { ret: -1, errno: code, data: b"", opened: None, }
          error => raise error
        }
      })
      job.result = Some(
        match result {
          Some(result) => result
          None =>
            {
              ret: -1,
              errno: if @async.platform is Windows {
                995
              } else {
                4
              },
              data: b"",
              opened: None,
            }
        },
      )
      job.running = false
      worker.done = true
      if !self.shutting_down && !worker.detached {
        if worker.completion is Some(fd) {
          fd.retain()
          defer fd.release()
          let data = Bytes::from_array(
            Array::makei(4, byte => {
              (id.reinterpret_as_uint() >> (byte * 8)).to_byte()
            }),
          )
          let mut offset = 0
          while offset < 4 {
            let result = self.stdio.write_fd(fd, data[offset:].to_owned(), -1L)
            guard result.ret > 0 else {
              raise @sys.Operation("failed to write worker completion")
            }
            offset += result.ret
          }
        } else if self.pool is Some(pool) {
          pool.notify(id)
        }
      }
    }),
  )
}

///|
pub fn AsyncHost::initialize_thread_pool(
  self : AsyncHost,
  bus_handle : Int64,
) -> Int64 raise @sys.HostError {
  guard self.pool is None && self.buses.get(bus_handle) is Some(bus) else {
    raise @sys.Invalid
  }
  let source = self.handles.allocate()
  let endpoints = FixedArray::make(2, @sys.invalid_native_fd())
  if !(@async.platform is Windows) {
    guard @sys.create_guest_pipe(endpoints, true, true) == 0 else {
      raise @sys.Operation("failed to create worker completion pipe")
    }
    if @sys.register_completion_fd(bus.native, endpoints[0], source) < 0 {
      ignore(@sys.close_guest_pipe(endpoints[0]))
      ignore(@sys.close_guest_pipe(endpoints[1]))
      raise @sys.Operation("failed to register worker completion pipe")
    }
  }
  self.pool = Some({
    bus,
    source,
    read: endpoints[0],
    write: endpoints[1],
    completed: [],
    offset: 0,
    closed: false,
  })
  source
}

///|
pub fn AsyncHost::destroy_thread_pool(self : AsyncHost) -> Unit {
  if self.pool is Some(pool) {
    pool.close()
  }
  self.pool = None
  for _, worker in self.workers {
    if worker.task is Some(task) {
      task.cancel()
    }
  }
}

///|
pub fn AsyncHost::spawn_worker(
  self : AsyncHost,
  id : Int32,
  job : Job,
  completion : @resource.Resource?,
) -> Int64 raise @sys.HostError {
  if completion is Some(fd) {
    guard fd.owner is Pipe(_, false) && fd.guest_async else {
      raise @sys.Invalid
    }
  }
  let worker : Worker = {
    task: None,
    done: false,
    completion,
    detached: false,
    completion_owned: false,
  }
  if completion is Some(fd) {
    fd.retain()
    worker.completion_owned = true
  }
  errdefer worker.close()
  self.start_worker(worker, id, job)
  let handle = self.handles.allocate()
  self.workers[handle] = worker
  handle
}

///|
pub fn ThreadPool::fetch_completion(
  self : ThreadPool,
  capacity : Int32,
) -> Array[Int32] raise @sys.HostError {
  let count = @cmp.minimum(capacity, self.completed.length() - self.offset)
  let completed = self.completed[self.offset:self.offset + count].to_owned()
  self.offset += count
  if count > 0 && self.offset == self.completed.length() {
    guard @sys.drain_completion(self.read) == 1 else {
      raise @sys.Operation("failed to drain worker completion pipe")
    }
    self.completed.clear()
    self.offset = 0
  }
  completed
}

///|
pub async fn Job::run_inline(self : Job) -> Unit {
  guard !self.running && self.result is None else { raise @sys.Invalid }
  self.running = true
  defer {
    self.running = false
  }
  self.result = Some(
    (self.action)() catch {
      @os_error.OSError(code, ..) =>
        { ret: -1, errno: code, data: b"", opened: None, }
      error => raise error
    },
  )
}

///|
pub fn Worker::close(self : Worker) -> Unit {
  if self.completion_owned {
    self.completion_owned = false
    if self.completion is Some(fd) {
      fd.release()
    }
  }
}

///|
pub fn Worker::detach(self : Worker) -> Unit {
  self.detached = true
  if self.done {
    self.close()
  }
  if self.task is Some(task) {
    task.cancel()
  }
}
