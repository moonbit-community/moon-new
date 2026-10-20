///|
pub fn AsyncHost::realpath_result(
  self : AsyncHost,
  job_handle : Int64,
) -> Int64 raise @sys.HostError {
  guard self.jobs.get(job_handle) is Some(job) &&
    !job.running &&
    job.result is Some(result) &&
    result.ret >= 0 else {
    raise @sys.Invalid
  }
  if job.result_handle is Some(BorrowedBuffer(handle)) {
    return handle
  }
  guard job.result_handle is None else { raise @sys.Invalid }
  let handle = self.handles.allocate()
  self.buffers[handle] = result.data.to_fixedarray()
  job.result_handle = Some(BorrowedBuffer(handle))
  let cleanup = job.cleanup
  let buffers = self.buffers
  // This result is borrowed from the job, not transferred to the guest.
  job.cleanup = Some(() => {
    buffers.remove(handle)
    if cleanup is Some(cleanup) {
      cleanup()
    }
  })
  handle
}

///|
pub fn AsyncHost::open_job_fd(
  self : AsyncHost,
  job_handle : Int64,
) -> Int64 raise @sys.HostError {
  if self.jobs.get(job_handle) is Some(job) &&
    job.result_handle is Some(OpenedFile(handle)) {
    return handle
  }
  guard self.jobs.get(job_handle) is Some(job) &&
    job.result is Some(result) &&
    result.ret >= 0 &&
    result.opened is Some(fd) else {
    raise @sys.Invalid
  }
  let handle = self.handles.allocate()
  result.opened = None
  self.fds[handle] = fd
  job.result_handle = Some(OpenedFile(handle))
  handle
}

///|
pub fn AsyncHost::addrinfo_result(
  self : AsyncHost,
  job_handle : Int64,
) -> Int64 raise @sys.HostError {
  guard self.jobs.get(job_handle) is Some(job) &&
    !job.running &&
    job.result is Some(result) &&
    result.ret == 0 &&
    result.errno == 0 else {
    raise @sys.Invalid
  }
  if job.result_handle is Some(ResolvedAddresses(handle)) {
    return handle
  }
  guard job.result_handle is None else { raise @sys.Invalid }
  let addresses : Array[Bytes] = []
  let data = result.data.to_fixedarray()
  let mut offset = 0
  while offset < data.length() {
    let length = @sys.buffer_word(data, offset, 4).to_int()
    @sys.check_range(offset + 4, length, data.length())
    let address = result.data[offset + 4:offset + 4 + length].to_owned()
    ignore(@sys.decode_address(address))
    addresses.push(address)
    offset += 4 + length
  }
  let mut next = self.handles.null_handle
  for index = addresses.length() - 1; index >= 0; index = index - 1 {
    let handle = self.handles.allocate()
    self.address_info[handle] = { address: addresses[index], next, }
    next = handle
  }
  job.result_handle = Some(ResolvedAddresses(next))
  next
}

///|
pub fn AsyncHost::new_spawn_job(
  self : AsyncHost,
  process : @process.HostProcess,
  spawn : @process.SpawnOptions,
) -> Int64 {
  for fd in spawn.stdio {
    if fd is Some(fd) {
      fd.retain()
    }
  }
  let handle = self.handles.allocate()
  self.jobs[handle] = {
    action: () => process.spawn_child(spawn),
    cleanup: Some(() => {
      for fd in spawn.stdio {
        if fd is Some(fd) {
          fd.release()
        }
      }
    }),
    result: None,
    running: false,
    result_handle: None,
    spawn: Some(spawn),
    sqlite: None,
    detached: false,
  }
  handle
}

///|
pub fn AsyncHost::spawn_job_result(
  self : AsyncHost,
  process : @process.HostProcess,
  handle : Int64,
) -> Int64 raise @os_error.OSError {
  guard self.jobs.get(handle) is Some(job) &&
    job.spawn is Some(spawn) &&
    spawn.child is Some(child) else {
    return self.handles.null_handle
  }
  if job.result_handle is Some(SpawnedProcess(handle)) {
    return handle
  }
  let handle = process.publish_child(child)
  job.result_handle = Some(SpawnedProcess(handle))
  handle
}
