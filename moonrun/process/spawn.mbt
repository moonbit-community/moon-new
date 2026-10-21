///|
pub fn HostProcess::spawn_child(
  self : HostProcess,
  spawn : SpawnOptions,
) -> @resource.Task raise {
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
  let input = if @sys.platform is Windows {
    @utf16.encode(text, endianness=Little, bom=false)
  } else {
    @utf8.encode(text)
  }
  let descriptors = spawn.stdio.map(fd => {
    fd.map(fd => fd.native()).unwrap_or_else(@sys.invalid_native_fd)
  })
  let child_pipes : Array[@sys.Fd] = []
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
      streams.push({ pipe, index, id, closed: false, input: b"", offset: 0, })
    }
  }
  let operation = @sys.spawn_operation(
    input,
    input.length(),
    spawn.args.length(),
    environment.length(),
    descriptors[0],
    descriptors[1],
    descriptors[2],
    spawn.orphan,
    spawn.no_console,
    transfer,
    transfer.length(),
  )
  streams_started = true
  let published = Ref(false)
  @resource.Task(
    operation,
    publish=() => {
      let result = @resource.result(operation)
      if result.ret <= 0 {
        for stream in streams {
          stream.close()
        }
        return result
      }
      let native = @sys.take_child(operation)
      let notification = @sys.take_child_pipe(operation)
      let child : Child = {
        native,
        pid: result.ret,
        identity: self.handles.allocate(),
        completion: Some(
          FixedArray::makei(2, index => {
            if index == 0 {
              notification
            } else {
              @sys.invalid_native_fd()
            }
          }),
        ),
        result: None,
        error: 0,
        consumed: false,
        handles: 0,
        closed: false,
        orphan: spawn.orphan,
        streams,
      }
      published.val = true
      self.children[result.ret] = child
      self.owned_children.push(child)
      spawn.child = Some(child)
      result
    },
    cleanup=() => {
      for fd in child_pipes {
        ignore(@sys.close_guest_pipe(fd))
      }
      if !published.val {
        for stream in streams {
          stream.close()
        }
      }
    },
  )
}
