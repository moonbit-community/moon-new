///|
pub struct Job {
  priv action : () -> @resource.Task raise
  priv mut cleanup : (() -> Unit)?
  priv mut work : @resource.Task?
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
  if self.work is Some(work) {
    self.work = None
    work.close()
  }
  if self.cleanup is Some(cleanup) {
    self.cleanup = None
    cleanup()
  }
}

///|
pub struct Worker {
  mut task : @sys.Worker?
  priv mut job : Job?
  mut done : Bool
  completion : @resource.Resource?
  mut detached : Bool
}

///|
pub struct ThreadPool {
  bus : @sys.EventBus
  source : Int64
  read : @sys.Fd
  write : @sys.Fd
  mut closed : Bool
  priv signals : Array[Int32]
}

///|
pub fn ThreadPool::close(self : ThreadPool) -> Unit {
  if !self.closed {
    self.closed = true
    if !(@sys.platform is Windows) {
      ignore(@sys.close_guest_pipe(self.read))
      ignore(@sys.close_guest_pipe(self.write))
    }
  }
}

///|
pub fn ThreadPool::notify(
  self : ThreadPool,
  id : Int32,
) -> Unit raise @sys.HostError {
  if self.closed || self.bus.closed {
    return
  }
  if @sys.platform is Windows {
    if @sys.post_completion(self.bus.native, self.source, 0L, id) < 0 {
      raise @sys.Operation("failed to post worker completion")
    }
  } else {
    let was_empty = self.signals.is_empty()
    self.signals.push(id)
    if was_empty && @sys.signal_completion(self.write) != 1 {
      raise @sys.Operation("failed to signal worker completion")
    }
  }
}

///|
pub fn AsyncHost::new_job(
  self : AsyncHost,
  action : () -> @resource.Task raise,
  cleanup? : () -> Unit,
  sqlite? : @sqlite.Job,
) -> Int64 {
  let handle = self.handles.allocate()
  self.jobs[handle] = {
    action,
    cleanup,
    work: None,
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
fn Job::prepare(self : Job) -> @resource.Task raise {
  (self.action)() catch {
    @sys.OSError(code, ..) =>
      @resource.Task::ready({ ret: -1, errno: code, data: b"", opened: None, })
    error => raise error
  }
}

///|
pub fn AsyncHost::start_worker(
  self : AsyncHost,
  worker : Worker,
  id : Int32,
  job : Job,
) -> Unit raise {
  guard !job.running &&
    job.result is None &&
    (
      worker.completion is Some(_) ||
      (self.pool is Some(pool) && !pool.closed && !pool.bus.closed)
    ) else {
    raise @sys.Invalid
  }
  if worker.task is Some(task) {
    task.close()
    worker.task = None
  }
  let work = job.prepare()
  job.work = Some(work)
  let notify = match worker.completion {
    Some(fd) => fd.native()
    None => self.pool.unwrap().write
  }
  let bus = if worker.completion is Some(_) {
    @sys.null_event_bus()
  } else {
    self.pool.map(pool => pool.bus.native).unwrap_or_else(@sys.null_event_bus)
  }
  let source = self.pool.map(pool => pool.source).unwrap_or(0L)
  worker.task = Some(
    @sys.start_worker(work.operation.raw(), id, notify, bus, source, 0L),
  )
  if worker.task is Some(task) && task.is_null() {
    worker.task = None
    @sys.check_errno("native worker startup")
  }
  worker.job = Some(job)
  worker.done = false
  job.running = true
}

///|
pub fn AsyncHost::refresh(self : AsyncHost) -> Unit raise {
  for _, io in self.io_results {
    if io.result is None &&
      io.task is Some(task) &&
      task.poll() &&
      io.work is Some(work) {
      io.result = Some(work.publish())
      task.close()
      io.task = None
      work.close()
      io.work = None
      if io.resource is Some(fd) {
        fd.release()
        io.resource = None
      }
    }
  }
  for _, worker in self.workers {
    if !worker.done &&
      worker.task is Some(task) &&
      task.poll() &&
      worker.job is Some(job) {
      guard job.work is Some(work) else { raise @sys.Invalid }
      job.result = Some(work.publish())
      job.running = false
      worker.done = true
      if job.detached {
        job.dispose()
      }
    }
  }
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
  if !(@sys.platform is Windows) {
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
    closed: false,
    signals: [],
  })
  source
}

///|
pub fn AsyncHost::destroy_thread_pool(self : AsyncHost) -> Unit {
  for _, worker in self.workers {
    worker.close()
  }
  if self.pool is Some(pool) {
    pool.close()
  }
  self.pool = None
}

///|
pub fn AsyncHost::spawn_worker(
  self : AsyncHost,
  id : Int32,
  job : Job,
  completion : @resource.Resource?,
) -> Int64 raise {
  if completion is Some(fd) {
    guard fd.owner is Pipe(_, false) && fd.guest_async else {
      raise @sys.Invalid
    }
    fd.retain()
  }
  let worker : Worker = {
    task: None,
    job: None,
    done: false,
    completion,
    detached: false,
  }
  errdefer worker.close()
  self.start_worker(worker, id, job)
  let handle = self.handles.allocate()
  self.workers[handle] = worker
  handle
}

///|
pub fn AsyncHost::fetch_completion(
  self : AsyncHost,
  capacity : Int32,
) -> Array[Int32] raise {
  guard self.pool is Some(pool) else { raise @sys.Invalid }
  // Drain wake bytes before reading notice flags. Re-arm if the guest's
  // result buffer cannot hold every pending notice; concurrent posts may
  // leave a harmless extra wake byte, but no completed job can be lost.
  let wake = FixedArray::make(4096, b'\x00')
  while @sys.read_guest_pipe(pool.read, wake, wake.length()) > 0 {

  }
  let output = []
  while output.length() < capacity && !pool.signals.is_empty() {
    output.push(pool.signals.remove(0))
  }
  for _, worker in self.workers {
    if output.length() < capacity &&
      worker.task is Some(task) &&
      task.take_notice() {
      output.push(task.id())
    }
  }
  if !pool.signals.is_empty() ||
    self.workers
    .values()
    .any(worker => worker.task is Some(task) && task.has_notice()) {
    if @sys.signal_completion(pool.write) != 1 {
      raise @sys.Operation("failed to re-arm worker completion")
    }
  }
  output
}

///|
pub fn Job::run_inline(
  self : Job,
  poll~ : () -> Unit raise = () => (),
) -> Unit raise {
  guard !self.running && self.result is None else { raise @sys.Invalid }
  let work = self.prepare()
  defer work.close()
  let worker = @sys.start_worker(
    work.operation.raw(),
    0,
    @sys.invalid_native_fd(),
    @sys.null_event_bus(),
    0L,
    0L,
  )
  if worker.is_null() {
    @sys.check_errno("native worker startup")
  }
  defer worker.close()
  self.running = true
  defer {
    self.running = false
  }
  while !worker.done() {
    poll()
    @sys.sleep(1)
  }
  self.result = Some(work.publish())
}

///|
pub fn Worker::close(self : Worker) -> Unit {
  if self.detached {
    return
  }
  self.detached = true
  if self.task is Some(task) {
    task.close()
    self.task = None
  }
  if self.job is Some(job) {
    job.running = false
    if job.detached {
      job.dispose()
    }
  }
  if self.completion is Some(fd) {
    fd.release()
  }
  self.done = true
}

///|
pub fn Worker::detach(self : Worker) -> Unit {
  self.close()
}
