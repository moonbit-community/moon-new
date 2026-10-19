///|
pub async fn HostProcess::spawn_child(
  self : HostProcess,
  spawn : SpawnOptions,
) -> @resource.JobResult {
  if self.policy is Some(policy) &&
    !policy.allows_process(spawn.command, spawn.args) {
    self.stdio.deny("process spawn")
  }
  let inherited = self.policy.filter(_ => @policy.invokes_moonx(spawn.command))
  let environment = if inherited is Some(_) {
    spawn.env.filter(entry => {
      let key = entry[:entry.find("=").unwrap_or(entry.length())].to_owned()
      !@sys.environment_key_equal(
        key,
        key.length(),
        "MOONRUN_INHERITED_POLICY",
        "MOONRUN_INHERITED_POLICY".length(),
      )
    })
  } else {
    spawn.env
  }
  let transfer = inherited
    .map(policy => @utf8.encode(policy.inherited_json()))
    .unwrap_or(b"")
  let parts = [spawn.command, spawn.cwd, ..spawn.args, ..environment, ""]
  let text = parts.map(truncate_nul).join("\u0000") + "\u0000"
  let input = if @async.platform is Windows {
    @utf16.encode(text, endianness=Little, bom=false)
  } else {
    @utf8.encode(text)
  }
  let (read, write) = @pipe.pipe()
  defer write.close()
  let mut transferred = false
  defer (if !transferred { read.close() })
  let descriptors = spawn.stdio.map(fd => {
    fd.map(fd => fd.native()).unwrap_or_else(@sys.invalid_native_fd)
  })
  let child_pipes : Array[@types.Fd] = []
  defer (for fd in child_pipes {
    ignore(@sys.close_guest_pipe(fd))
  })
  let output_tasks : Array[(ChildStream, @async.Task[Unit])] = []
  let completion = if @async.platform is Linux {
    let pipe = FixedArray::make(2, @sys.invalid_native_fd())
    if @sys.create_guest_pipe(pipe, true, true) < 0 {
      @os_error.check_errno("process completion pipe")
    }
    Some(pipe)
  } else {
    None
  }
  let mut attached = false
  defer (if !attached && completion is Some(pipe) {
    ignore(@sys.close_guest_pipe(pipe[0]))
    ignore(@sys.close_guest_pipe(pipe[1]))
  })
  let streams : Array[ChildStream] = []
  let mut streams_started = false
  defer (if !streams_started {
    for stream in streams {
      stream.close()
    }
  })
  for index in 0..<3 {
    if self.child_stream(spawn.stdio[index], index) is Some((fd, pipe, id)) {
      child_pipes.push(fd)
      descriptors[index] = fd
      streams.push({ pipe, index, id, closed: false, })
    }
  }
  let native = @sys.start_child(
    input,
    input.length(),
    spawn.args.length(),
    environment.length(),
    descriptors[0],
    descriptors[1],
    descriptors[2],
    spawn.orphan,
    spawn.no_console,
    write.fd(),
    transfer,
    transfer.length(),
  )
  let error = @os_error.get_errno()
  write.close()
  guard !@sys.child_is_null(native) else {
    raise @os_error.OSError(error, context="spawn child")
  }
  defer (if !attached { @sys.free_child(native) })
  // Do not abandon a successful spawn before attaching its lifetime to the run.
  @async.protect_from_cancel(() => {
    ignore(read.read_exactly(1))
    let pid = @sys.child_pid(native)
    let error = @sys.child_error(native)
    if pid == 0 {
      ignore(read.read_exactly(1))
      @sys.join_child(native)
      return { ret: 0, errno: error, data: b"", opened: None, }
    }
    let identity = self.handles.allocate()
    let child = Child::{
      native,
      identity,
      completion,
      result: None,
      error: 0,
      consumed: false,
      handles: 0,
      closed: false,
    }
    self.children[pid] = child
    self.owned_children.push(child)
    attached = true
    spawn.child = Some(child)
    for stream in streams {
      self.group.add_defer(() => stream.close())
      let task = self.group.spawn(no_wait=true, () => {
        self.forward_child_stream(stream)
      })
      if stream.index != 0 {
        output_tasks.push((stream, task))
      }
    }
    streams_started = true
    self.group.spawn_bg(no_wait=true, () => {
      defer read.close()
      let done = @async.handle_cancellation(() => read.read_exactly(1))
      if done is None {
        if spawn.orphan {
          return
        }
        @sys.child_signal(native, -1)
        @async.protect_from_cancel(() => ignore(read.read_exactly(1)))
      }
      @sys.join_child(native)
      // Flush already produced output before publishing the child's status.
      // Cancellation drains a finite snapshot instead of waiting for EOF from
      // descendants. Resume forwarding those descendants for the rest of the run.
      for pair in output_tasks {
        pair.1.cancel()
      }
      for pair in output_tasks {
        let (stream, task) = pair
        task.wait() catch {
          @async.WaitedTaskAlreadyCancelled => ()
          error => raise error
        }
        if !stream.closed {
          self.group.spawn_bg(no_wait=true, () => {
            defer stream.close()
            self.forward_child_stream(stream)
          })
        }
      }
      child.result = Some(@sys.child_status(native))
      child.error = @sys.child_error(native)
      // Publish the cached status before exposing readiness to the guest.
      // The OS pidfd exit edge can arrive before native async delivers our pipe.
      if completion is Some(pipe) && @sys.signal_completion(pipe[1]) != 1 {
        raise @sys.Operation("failed to signal process completion")
      }
    })
    transferred = true
    { ret: pid, errno: 0, data: b"", opened: None, }
  })
}
