///|
pub(all) struct AsyncHost {
  handles : @handles.Handles
  stdio : @stdio.Stdio
  buffers : Map[Int64, FixedArray[Byte]]
  buses : Map[Int64, @sys.EventBus]
  fds : Map[Int64, @resource.Resource]
  stdio_handles : Map[Int32, Int64]
  jobs : Map[Int64, Job]
  workers : Map[Int64, Worker]
  io_results : Map[Int64, @resource.IoResult]
  address_info : Map[Int64, AddrInfo]
  accepting : Set[Int64]
  mut pool : ThreadPool?
  mut shutting_down : Bool
  signals : Set[Int32]
  signal_waiters : Map[Int64, SignalWaiter]
  mut signal_enabled : Bool
  mut termination_signal : Int32?
  mut current_bus : Int64?
  mut async_errno : Int32
}

///|
pub fn AsyncHost::AsyncHost(
  handles : @handles.Handles,
  stdio : @stdio.Stdio,
) -> AsyncHost {
  {
    handles,
    stdio,
    buffers: Map([]),
    buses: Map([]),
    fds: Map([]),
    stdio_handles: Map([]),
    jobs: Map([]),
    workers: Map([]),
    io_results: Map([]),
    address_info: Map([]),
    accepting: Set([]),
    pool: None,
    shutting_down: false,
    signals: Set([]),
    signal_waiters: Map([]),
    signal_enabled: false,
    termination_signal: None,
    current_bus: None,
    async_errno: 0,
  }
}

///|
// Stop native workers before releasing jobs, completion endpoints, or descriptors.
pub fn AsyncHost::close(self : AsyncHost) -> Unit {
  for _, io in self.io_results {
    if io.task is Some(task) {
      task.close()
      io.task = None
    }
    if io.work is Some(work) {
      work.close()
      io.work = None
    }
    if io.resource is Some(fd) {
      fd.release()
      io.resource = None
    }
  }
  for _, worker in self.workers {
    worker.close()
  }
  for _, bus in self.buses {
    bus.close()
  }
  self.buses.clear()
  if self.pool is Some(pool) {
    pool.close()
    self.pool = None
  }
  for _, job in self.jobs {
    job.dispose()
  }
  self.jobs.clear()
  self.workers.clear()
  self.io_results.clear()
  self.address_info.clear()
  for _, fd in self.fds {
    fd.release()
  }
  self.fds.clear()
  self.buffers.clear()
}
