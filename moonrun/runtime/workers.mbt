///|
priv struct JobResult {
  ret : Int32
  errno : Int32
  data : Bytes
  mut opened : GuestFd?
}

///|
priv struct GuestJob {
  action : async () -> JobResult
  cleanup : (() -> Unit)?
  mut result : JobResult?
  mut running : Bool
  mut result_handle : JobHandleResult?
  mut spawn : GuestSpawn?
}

///|
priv enum JobHandleResult {
  OpenedFile(Int64)
  ResolvedAddresses(Int64)
  SpawnedProcess(Int64)
}

///|
fn GuestJob::dispose(self : GuestJob) -> Unit {
  if self.result is Some(result) && result.opened is Some(fd) {
    fd.release()
    result.opened = None
  }
  if self.cleanup is Some(cleanup) {
    cleanup()
  }
}

///|
priv struct GuestWorker {
  mut task : @async.Task[Unit]?
  mut done : Bool
  completion : GuestFd?
}

///|
priv struct GuestThreadPool {
  bus : GuestEventBus
  source : Int64
  read : @types.Fd
  write : @types.Fd
  completed : Array[Int32]
  mut offset : Int32
  mut closed : Bool
}

///|
extern "C" fn signal_completion(fd : @types.Fd) -> Int32 = "moonrun_completion_signal"

///|
extern "C" fn drain_completion(fd : @types.Fd) -> Int32 = "moonrun_completion_drain"

///|
fn GuestThreadPool::close(self : GuestThreadPool) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  if !(@async.platform is Windows) {
    ignore(close_guest_pipe(self.read))
    ignore(close_guest_pipe(self.write))
  }
  self.completed.clear()
}

///|
fn GuestThreadPool::notify(
  self : GuestThreadPool,
  id : Int32,
) -> Unit raise @vm.RuntimeError {
  if self.closed || self.bus.closed {
    return
  }
  if @async.platform is Windows {
    if post_completion(self.bus.native, self.source, 0L, id) < 0 {
      raise @vm.LinkErrorDetail("failed to post worker completion")
    }
  } else {
    let was_empty = self.offset == self.completed.length()
    self.completed.push(id)
    if was_empty && signal_completion(self.write) != 1 {
      raise @vm.LinkErrorDetail("failed to signal worker completion")
    }
  }
}

///|
fn Host::new_job(
  self : Host,
  action : async () -> JobResult,
  cleanup? : () -> Unit,
) -> Array[@wasm.Value] {
  let handle = self.next_handle
  self.next_handle += 1L
  self.jobs[handle] = {
    action,
    cleanup,
    result: None,
    running: false,
    result_handle: None,
    spawn: None,
  }
  [I64(handle)]
}

///|
fn Host::start_worker(
  self : Host,
  worker : GuestWorker,
  id : Int32,
  job : GuestJob,
) -> Unit raise @vm.RuntimeError {
  guard !job.running &&
    job.result is None &&
    (worker.completion is Some(_) || (self.pool is Some(pool) && !pool.closed)) else {
    raise @vm.TypeMismatch
  }
  worker.done = false
  job.running = true
  worker.task = Some(
    self.group.spawn(no_wait=true, () => {
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
      if !self.shutting_down {
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
            let result = self.write_fd(fd, data[offset:].to_owned(), -1L)
            guard result.ret > 0 else {
              raise @vm.LinkErrorDetail("failed to write worker completion")
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
fn Host::worker_import(
  self : Host,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  match name {
    name if name != "thread_pool/spawn_worker_with_pipe" &&
      legacy_async_signature(name) is Some(_) =>
      self.legacy_async_import(caller, name, args)
    name if process_signature(name) is Some(_) =>
      self.process_import(caller, name, args)
    name if watcher_signature(name) is Some(_) =>
      self.watcher_import(caller, name, args)
    "thread_pool/make_bind_job" => self.socket_bind_job(caller, args)
    "thread_pool/make_getaddrinfo_job" | "thread_pool/get_getaddrinfo_result" =>
      self.dns_import(caller, name, args)
    "thread_pool/init_thread_pool" => {
      guard self.pool is None && self.buses.get(i64(args[0])) is Some(bus) else {
        raise @vm.TypeMismatch
      }
      let source = self.next_handle
      self.next_handle += 1L
      let endpoints = FixedArray::make(2, invalid_native_fd())
      if !(@async.platform is Windows) {
        guard create_guest_pipe(endpoints, true, true) == 0 else {
          raise @vm.LinkErrorDetail("failed to create worker completion pipe")
        }
        if register_completion_fd(bus.native, endpoints[0], source) < 0 {
          ignore(close_guest_pipe(endpoints[0]))
          ignore(close_guest_pipe(endpoints[1]))
          raise @vm.LinkErrorDetail("failed to register worker completion pipe")
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
      [I64(source)]
    }
    "thread_pool/destroy_thread_pool" => {
      if self.pool is Some(pool) {
        pool.close()
      }
      self.pool = None
      for _, worker in self.workers {
        if worker.task is Some(task) {
          task.cancel()
        }
      }
      []
    }
    "thread_pool/make_sleep_job" => {
      let duration = i32(args[0])
      guard duration >= 0 else { raise @vm.TypeMismatch }
      self.new_job(() => {
        @async.sleep(duration)
        { ret: 0, errno: 0, data: b"", opened: None, }
      })
    }
    "thread_pool/spawn_worker" | "thread_pool/spawn_worker_with_pipe" => {
      guard self.jobs.get(i64(args[1])) is Some(job) else {
        raise @vm.TypeMismatch
      }
      let completion = if name == "thread_pool/spawn_worker_with_pipe" {
        guard self.fds.get(i64(args[2])) is Some(fd) else {
          raise @vm.TypeMismatch
        }
        Some(fd)
      } else {
        None
      }
      let worker = { task: None, done: false, completion, }
      let handle = self.next_handle
      self.next_handle += 1L
      self.workers[handle] = worker
      self.start_worker(worker, i32(args[0]), job)
      if completion is Some(fd) {
        fd.retain()
      }
      [I64(handle)]
    }
    "thread_pool/wake_worker" => {
      guard self.workers.get(i64(args[0])) is Some(worker) &&
        worker.done &&
        self.jobs.get(i64(args[2])) is Some(job) else {
        raise @vm.TypeMismatch
      }
      self.start_worker(worker, i32(args[1]), job)
      []
    }
    "thread_pool/free_worker" | "thread_pool/worker_enter_idle" => {
      guard self.workers.get(i64(args[0])) is Some(worker) && worker.done else {
        raise @vm.TypeMismatch
      }
      if name == "thread_pool/free_worker" {
        self.workers.remove(i64(args[0]))
        if worker.completion is Some(fd) {
          fd.release()
        }
      }
      []
    }
    "thread_pool/cancel_worker" | "thread_pool/cancel_worker_with_retry" => {
      guard self.workers.get(i64(args[0])) is Some(worker) else {
        raise @vm.TypeMismatch
      }
      if worker.done {
        [I32(2)]
      } else {
        if worker.task is Some(task) {
          task.cancel()
        }
        [I32(1)]
      }
    }
    "thread_pool/job_get_ret"
    | "thread_pool/job_get_err"
    | "thread_pool/free_job" => {
      let handle = i64(args[0])
      guard self.jobs.get(handle) is Some(job) && !job.running else {
        raise @vm.TypeMismatch
      }
      if name == "thread_pool/free_job" {
        self.jobs.remove(handle)
        job.dispose()
        []
      } else {
        guard job.result is Some(result) else { raise @vm.TypeMismatch }
        [
          I32(
            if name == "thread_pool/job_get_ret" {
              result.ret
            } else {
              result.errno
            },
          ),
        ]
      }
    }
    "thread_pool/fetch_completion/unix" => {
      guard self.pool is Some(pool) &&
        !pool.closed &&
        pool.source == i64(args[0]) else {
        self.async_errno = bad_fd_errno
        return [I32(-1)]
      }
      let memory = guest_memory(caller)
      let address = i32(args[1]).reinterpret_as_uint().to_int64()
      let capacity = i32(args[2])
      guard capacity >= 0 &&
        address + capacity.to_int64() * 4L <= memory.byte_len() else {
        self.async_errno = fault_errno
        return [I32(-1)]
      }
      let count = @cmp.minimum(capacity, pool.completed.length() - pool.offset)
      for index in 0..<count {
        memory.store_i32_at(
          address + index.to_int64() * 4L,
          pool.completed[pool.offset + index],
        )
      }
      pool.offset += count
      if count > 0 && pool.offset == pool.completed.length() {
        guard drain_completion(pool.read) == 1 else {
          raise @vm.LinkErrorDetail("failed to drain worker completion pipe")
        }
        pool.completed.clear()
        pool.offset = 0
      }
      [I32(count * 4)]
    }
    "thread_pool/errno_is_cancelled" =>
      [
        I32(
          if i32(args[0]) == (if @async.platform is Windows { 995 } else { 4 }) {
            1
          } else {
            0
          },
        ),
      ]
    _ => self.file_job_import(caller, name, args)
  }
}
