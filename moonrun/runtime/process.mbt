///|
#external
priv type NativeChild

///|
extern "C" fn initialize_child_signals() -> Unit = "moonrun_child_init"

///|
fn init {
  // Capture before async installs its host signal mask. Child processes inherit
  // the caller's ambient mask rather than the event loop's private one.
  initialize_child_signals()
}

///|
#borrow(input, policy)
extern "C" fn start_child(
  input : Bytes,
  length : Int32,
  argc : Int32,
  envc : Int32,
  stdin : @types.Fd,
  stdout : @types.Fd,
  stderr : @types.Fd,
  orphan : Bool,
  no_console : Bool,
  notify : @types.Fd,
  policy : Bytes,
  policy_length : Int32,
) -> NativeChild = "moonrun_child_start"

///|
extern "C" fn child_is_null(child : NativeChild) -> Bool = "moonrun_child_is_null"

///|
extern "C" fn child_pid(child : NativeChild) -> Int32 = "moonrun_child_pid"

///|
extern "C" fn child_error(child : NativeChild) -> Int32 = "moonrun_child_error"

///|
extern "C" fn child_status(child : NativeChild) -> Int32 = "moonrun_child_status"

///|
extern "C" fn child_handle(child : NativeChild) -> @types.Fd = "moonrun_child_handle"

///|
extern "C" fn child_signal(child : NativeChild, signal : Int32) -> Unit = "moonrun_child_signal"

///|
extern "C" fn join_child(child : NativeChild) -> Unit = "moonrun_child_join"

///|
extern "C" fn free_child(child : NativeChild) -> Unit = "moonrun_child_free"

///|
extern "C" fn open_native_process(pid : Int32) -> @types.Fd = "moonbitlang_async_open_pid_handle"

///|
#borrow(result)
extern "C" fn native_process_result(
  handle : @types.Fd,
  pid : Int32,
  result : Ref[Int32],
) -> Int32 = "moonbitlang_async_get_process_result"

///|
extern "C" fn native_process_fd_valid(handle : @types.Fd) -> Bool = "moonrun_process_fd_valid"

///|
extern "C" fn native_process_ready(handle : @types.Fd) -> Int32 = "moonrun_process_ready"

///|
extern "C" fn signal_process_pid(pid : Int32, signal : Int32) -> Unit = "moonrun_signal_process_pid"

///|
extern "C" fn buffered_pipe_bytes(fd : @types.Fd) -> Int32 = "moonrun_buffered_pipe_bytes"

///|
priv enum GuestProcessHandle {
  Child(GuestChild)
  External(GuestExternalProcess)
}

///|
priv struct GuestExternalProcess {
  fd : @types.Fd
  mut references : Int32
}

///|
fn GuestExternalProcess::release(self : GuestExternalProcess) -> Unit {
  self.references -= 1
  if self.references == 0 {
    ignore(close_guest_pipe(self.fd))
  }
}

///|
fn poll_process(handle : @types.Fd, pid : Int32) -> (Int32, Int32, Int32) {
  if @async.platform is Windows {
    let ready = native_process_ready(handle)
    if ready <= 0 {
      return (-1, if ready == 0 { 997 } else { @os_error.get_errno() }, 0)
    }
  }
  let output = Ref(0)
  let result = native_process_result(handle, pid, output)
  (result, if result < 0 { @os_error.get_errno() } else { 0 }, output.val)
}

///|
#borrow(left, right)
extern "C" fn environment_key_equal(
  left : String,
  left_len : Int32,
  right : String,
  right_len : Int32,
) -> Bool = "moonrun_environment_key_equal"

///|
priv enum GuestEnvironment {
  Entries(Array[GuestEnvironmentEntry?])
  Wide(FixedArray[Byte])
  Builder(Array[(String, String)], Array[String])
}

///|
priv enum GuestEnvironmentEntry {
  Materialized(String)
  Added(String, String)
}

///|
fn GuestEnvironmentEntry::materialize(self : GuestEnvironmentEntry) -> String? {
  match self {
    Materialized(entry) => Some(entry)
    Added(key, value) =>
      if key.contains_char('\u0000') {
        None
      } else {
        Some("\{key}=\{truncate_nul(value)}")
      }
  }
}

///|
priv struct GuestSpawn {
  command : String
  args : Array[String]
  env : Array[String]
  stdio : Array[GuestFd?]
  mut cwd : String
  orphan : Bool
  mut no_console : Bool
  mut child : GuestChild?
}

///|
priv struct GuestChild {
  native : NativeChild
  identity : Int64
  completion : FixedArray[@types.Fd]?
  mut result : Int32?
  mut error : Int32
  mut consumed : Bool
  mut handles : Int32
  mut closed : Bool
}

///|
fn GuestChild::release_if_finished(self : GuestChild) -> Unit {
  if self.consumed && self.handles == 0 && !self.closed {
    self.close()
  }
}

///|
fn GuestChild::close(self : GuestChild) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  if self.completion is Some(pipe) {
    ignore(close_guest_pipe(pipe[0]))
    ignore(close_guest_pipe(pipe[1]))
  }
  free_child(self.native)
}

///|
fn truncate_nul(text : String) -> String {
  match text.find("\u0000") {
    Some(index) => text[:index].to_owned()
    None => text
  }
}

///|
fn process_environment(
  entries : Array[String],
  extra : Array[(String, String)],
) -> Array[String] {
  let added = extra.filter_map(pair => {
    let (key, value) = pair
    if key.contains_char('\u0000') {
      None
    } else {
      Some((key, truncate_nul(value)))
    }
  })
  let result = added.map(pair => {
    let (key, value) = pair
    "\{key}=\{value}"
  })
  for entry in entries {
    let key = match entry.find("=") {
      Some(index) => entry[:index].to_owned()
      None => entry
    }
    if !added.any(pair => {
        let (existing, _) = pair
        environment_key_equal(existing, existing.length(), key, key.length())
      }) {
      result.push(entry)
    }
  }
  result
}

///|
fn GuestEnvironment::finish(
  self : GuestEnvironment,
) -> Array[String] raise @vm.RuntimeError {
  match self {
    Entries(entries) =>
      entries
      .iter()
      .take_while(entry => entry is Some(_))
      .filter_map(entry => entry.unwrap().materialize())
      .to_array()
    Builder(extra, inherited) => process_environment(inherited, extra)
    Wide(buffer) => {
      let text = @utf16.decode(Bytes::from_array(buffer), endianness=Little) catch {
        _ => raise @vm.TypeMismatch
      }
      text
      .split("\u0000")
      .take_while(entry => !entry.is_empty())
      .map(entry => entry.to_owned())
      .to_array()
    }
  }
}

///|
fn Host::inherited_process_env(self : Host) -> Array[String] {
  self.env
  .iter()
  .map(pair => {
    let (key, value) = pair
    "\{key}=\{value}"
  })
  .to_array()
}

///|
fn Host::put_process_env(
  self : Host,
  env : GuestEnvironment,
) -> Array[@wasm.Value] {
  let handle = self.next_handle
  self.next_handle += 1L
  self.process_env[handle] = env
  [I64(handle)]
}

///|
priv struct GuestChildStream {
  pipe : @raw_fd.RawFd
  index : Int32
  id : Int32
  mut closed : Bool
}

///|
fn GuestChildStream::close(self : GuestChildStream) -> Unit {
  if !self.closed {
    self.closed = true
    self.pipe.close()
  }
}

///|
async fn Host::forward_child_stream(
  self : Host,
  stream : GuestChildStream,
) -> Unit {
  let pipe = stream.pipe
  if stream.index == 0 {
    defer stream.close()
    try {
      for ;; {
        let data = self.read_chunk(4096)
        if data.is_empty() {
          break
        }
        let mut offset = 0
        while offset < data.length() {
          offset += pipe.write(data, offset~, len=data.length() - offset)
        }
      }
    } catch {
      @os_error.OSError(code, ..) if (if @async.platform is Windows {
          code is (109 | 232 | 233)
        } else {
          code == 32
        }) => ()
      error => raise error
    }
  } else {
    let buffer = FixedArray::make(4096, b'\x00')
    let finished = @async.handle_cancellation(() => {
      for ;; {
        let count = pipe.read(buffer)
        if count == 0 {
          break
        }
        self.output(stream.id, Bytes::from_array(buffer[:count]))
      }
    })
    if finished is None {
      // Preserve bytes produced before cancellation, without waiting for EOF
      // from descendants which may still hold a copy of the output writer.
      @async.protect_from_cancel(() => {
        let mut remaining = buffered_pipe_bytes(pipe.fd)
        if remaining < 0 {
          @os_error.check_errno("child output buffer")
        }
        while remaining > 0 {
          let count = pipe.read(
            buffer,
            max_len=@cmp.minimum(remaining, buffer.length()),
          )
          if count == 0 {
            break
          }
          self.output(stream.id, Bytes::from_array(buffer[:count]))
          remaining -= count
        }
      })
    } else {
      stream.close()
    }
  }
}

///|
async fn Host::child_stream(
  self : Host,
  descriptor : GuestFd?,
  index : Int32,
) -> (@types.Fd, @raw_fd.RawFd, Int32)? {
  let id = match descriptor {
    None => index
    Some(fd) =>
      match fd.owner {
        Standard(id, _) => id
        _ => return None
      }
  }
  if !(if id == 0 {
      self.stdin is Some(_)
    } else if id == 1 {
      self.stdout is Some(_)
    } else {
      self.stderr is Some(_)
    }) {
    return None
  }
  let endpoints = FixedArray::make(2, invalid_native_fd())
  if create_guest_pipe(endpoints, false, false) < 0 {
    @os_error.check_errno("process callback pipe")
  }
  let child = endpoints[if index == 0 { 0 } else { 1 }]
  errdefer ignore(close_guest_pipe(child))
  let pipe = @async.protect_from_cancel(() => {
    @raw_fd.RawFd(endpoints[if index == 0 { 1 } else { 0 }])
  })
  Some((child, pipe, id))
}

///|
async fn Host::spawn_child(self : Host, spawn : GuestSpawn) -> JobResult {
  if self.policy is Some(policy) &&
    !policy.allows_process(spawn.command, spawn.args) {
    self.deny("process spawn")
  }
  let inherited = self.policy.filter(_ => invokes_moonx(spawn.command))
  let environment = if inherited is Some(_) {
    spawn.env.filter(entry => {
      let key = entry[:entry.find("=").unwrap_or(entry.length())].to_owned()
      !environment_key_equal(
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
    fd.map(fd => fd.native()).unwrap_or_else(invalid_native_fd)
  })
  let child_pipes : Array[@types.Fd] = []
  defer (for fd in child_pipes {
    ignore(close_guest_pipe(fd))
  })
  let output_tasks : Array[(GuestChildStream, @async.Task[Unit])] = []
  let completion = if @async.platform is Linux {
    let pipe = FixedArray::make(2, invalid_native_fd())
    if create_guest_pipe(pipe, true, true) < 0 {
      @os_error.check_errno("process completion pipe")
    }
    Some(pipe)
  } else {
    None
  }
  let mut attached = false
  defer (if !attached && completion is Some(pipe) {
    ignore(close_guest_pipe(pipe[0]))
    ignore(close_guest_pipe(pipe[1]))
  })
  let streams : Array[GuestChildStream] = []
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
  let native = start_child(
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
  guard !child_is_null(native) else {
    raise @os_error.OSError(error, context="spawn child")
  }
  defer (if !attached { free_child(native) })
  // Do not abandon a successful spawn before attaching its lifetime to the run.
  @async.protect_from_cancel(() => {
    ignore(read.read_exactly(1))
    let pid = child_pid(native)
    let error = child_error(native)
    if pid == 0 {
      ignore(read.read_exactly(1))
      join_child(native)
      return { ret: 0, errno: error, data: b"", opened: None, }
    }
    let identity = self.next_handle
    self.next_handle += 1L
    let child = GuestChild::{
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
        child_signal(native, -1)
        @async.protect_from_cancel(() => ignore(read.read_exactly(1)))
      }
      join_child(native)
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
      child.result = Some(child_status(native))
      child.error = child_error(native)
      // Publish the cached status before exposing readiness to the guest.
      // The OS pidfd exit edge can arrive before native async delivers our pipe.
      if completion is Some(pipe) && signal_completion(pipe[1]) != 1 {
        raise @vm.LinkErrorDetail("failed to signal process completion")
      }
    })
    transferred = true
    { ret: pid, errno: 0, data: b"", opened: None, }
  })
}

///|
fn process_signature(name : String) -> @wasm.FuncType? {
  let (params, results) : (
    ReadOnlyArray[@wasm.ValueType],
    ReadOnlyArray[@wasm.ValueType],
  ) = match name {
    "process/get_curr_env" => ([], [I64])
    "process/make_env"
    | "process/allocate_env_block"
    | "process/make_argv_array/unix"
    | "process/open_pid_handle" => ([I32], [I64])
    "process/env_block_length" => ([I64], [I32])
    "process/free_env" | "process/free_argv" => ([I64], [])
    "process/write_env_block" => ([I64, I64], [])
    "process/env_block_add_entry" => ([I64, I32, I32, I32, I32, I32], [])
    "process/env_add_entry" => ([I64, I32, I32, I32, I32], [])
    "process/argv_array_add_entry/unix"
    | "process/argv_array_add_encoded_entry/unix" => ([I64, I32, I32, I32], [])
    "process/get_process_result" => ([I64, I32, I32], [I32])
    "process/terminate" => ([I32, I32], [])
    "process/kill" => ([I32], [])
    "event_bus/register_pid" => ([I64, I32], [I32])
    "thread_pool/spawn_job/unix" => ([I32, I32, I64, I64, I64, I64, I64], [I64])
    "thread_pool/make_spawn_job/unix" =>
      ([I32, I32, I64, I64, I32, I64, I64, I64, I32, I32, I32], [I64])
    "thread_pool/spawn_job/windows" =>
      ([I32, I32, I64, I64, I64, I64, I32], [I64])
    "thread_pool/make_spawn_job/windows" =>
      ([I32, I32, I64, I64, I64, I64, I32, I32, I32, I32, I32], [I64])
    "thread_pool/spawn_job/set_cwd" => ([I64, I32, I32], [])
    "thread_pool/spawn_job/set_no_console_window" => ([I64], [])
    "thread_pool/spawn_job_get_result_handle" => ([I64], [I64])
    "thread_pool/get_spawn_job_result_handle" => ([I64, I32], [I64])
    "thread_pool/make_wait_for_process_job" => ([I64, I32], [I64])
    _ => return None
  }
  Some({ params, results, })
}

///|
fn Host::process_import(
  self : Host,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  match name {
    "process/make_env" =>
      self.put_process_env(
        Builder(
          [],
          if i32(args[0]) != 0 {
            self.inherited_process_env()
          } else {
            []
          },
        ),
      )
    "process/get_curr_env" => {
      let entries = self.inherited_process_env()
      self.put_process_env(
        if @async.platform is Windows {
          Wide(
            @utf16.encode(
              entries.join("\u0000") + "\u0000\u0000",
              endianness=Little,
              bom=false,
            ).to_fixedarray(),
          )
        } else {
          Entries(entries.map(entry => Some(Materialized(entry))))
        },
      )
    }
    "process/allocate_env_block" => {
      let size = i32(args[0])
      guard size >= 0 && size < 0x3FFF_FFFF else {
        raise @vm.OutOfBoundsMemoryAccess
      }
      self.put_process_env(
        if @async.platform is Windows {
          Wide(FixedArray::make((size + 1) * 2, b'\x00'))
        } else {
          Entries(Array::make(size, None))
        },
      )
    }
    "process/free_env" | "process/free_argv" =>
      // Spawn consumes these handles in both the current and legacy ABIs.
      []
    "process/make_argv_array/unix" => {
      let length = i32(args[0])
      guard length >= 0 else { raise @vm.OutOfBoundsMemoryAccess }
      let handle = self.next_handle
      self.next_handle += 1L
      self.process_args[handle] = Array::make(length, None)
      [I64(handle)]
    }
    "process/argv_array_add_entry/unix"
    | "process/argv_array_add_encoded_entry/unix" => {
      guard self.process_args.get(i64(args[0])) is Some(entries) else {
        raise @vm.TypeMismatch
      }
      let index = i32(args[1])
      check_range(index, 1, entries.length())
      // OsString and String both cross the guest boundary as UTF-16.
      entries[index] = Some(guest_string(caller, i32(args[2]), i32(args[3])))
      []
    }
    "process/env_add_entry" | "process/env_block_add_entry" => {
      guard self.process_env.get(i64(args[0])) is Some(env) else {
        raise @vm.TypeMismatch
      }
      let base = if name == "process/env_add_entry" { 1 } else { 2 }
      let key = guest_string(caller, i32(args[base]), i32(args[base + 1]))
      let value = guest_string(caller, i32(args[base + 2]), i32(args[base + 3]))
      match env {
        Builder(extra, _) =>
          if !key.contains_char('\u0000') {
            extra.push((key, value))
          }
        Entries(entries) => {
          let index = i32(args[1])
          check_range(index, 1, entries.length())
          entries[index] = Some(Added(key, value))
        }
        Wide(buffer) => {
          if key.contains_char('\u0000') {
            return []
          }
          let data = @utf16.encode(
            "\{key}=\{truncate_nul(value)}\u0000",
            endianness=Little,
            bom=false,
          )
          let offset = i32(args[1]) * 2
          check_range(offset, data.length(), buffer.length())
          data
          .to_fixedarray()
          .blit_to(buffer, dst_offset=offset, len=data.length())
        }
      }
      []
    }
    "process/env_block_length" => {
      guard self.process_env.get(i64(args[0])) is Some(env) else {
        raise @vm.TypeMismatch
      }
      [
        I32(
          match env {
            Entries(entries) => entries.length()
            Wide(_) =>
              env.finish().fold(init=0, (n, entry) => n + entry.length() + 1)
            Builder(_, _) => raise @vm.TypeMismatch
          },
        ),
      ]
    }
    "process/write_env_block" => {
      guard self.process_env.get(i64(args[0])) is Some(dst) &&
        self.process_env.get(i64(args[1])) is Some(src) else {
        raise @vm.TypeMismatch
      }
      let inherited = src.finish()
      match dst {
        Entries(entries) => {
          let offset = entries
            .iter()
            .take_while(entry => entry is Some(_))
            .count()
          let extra = entries[:offset].filter_map(entry => {
            entry.unwrap().materialize()
          })
          let remaining = inherited.filter(entry => {
            !extra.any(existing => {
              existing.split("=").next() == entry.split("=").next()
            })
          })
          check_range(offset, remaining.length(), entries.length())
          for index, entry in remaining {
            entries[offset + index] = Some(Materialized(entry))
          }
        }
        Wide(buffer) => {
          let extra = dst
            .finish()
            .map(entry => {
              let index = entry.find("=").unwrap_or(entry.length())
              (
                entry[:index].to_owned(),
                if index < entry.length() {
                  entry[index + 1:].to_owned()
                } else {
                  ""
                },
              )
            })
          let data = @utf16.encode(
            process_environment(inherited, extra).join("\u0000") + "\u0000",
            endianness=Little,
            bom=false,
          )
          check_range(0, data.length(), buffer.length())
          data.to_fixedarray().blit_to(buffer, len=data.length())
        }
        Builder(_, _) => raise @vm.TypeMismatch
      }
      []
    }
    name if name == "thread_pool/spawn_job/unix" ||
      name == "thread_pool/spawn_job/windows" ||
      name == "thread_pool/make_spawn_job/unix" ||
      name == "thread_pool/make_spawn_job/windows" => {
      let windows = name.has_suffix("/windows")
      guard windows == (@async.platform is Windows) else {
        raise @vm.UnknownImport("moonbitlang/async", name)
      }
      let legacy = name.has_prefix("thread_pool/make_spawn_job/")
      let command = guest_string(caller, i32(args[0]), i32(args[1]))
      let env_index = if windows { 2 } else { 3 }
      guard self.process_env.get(i64(args[env_index])) is Some(env) else {
        raise @vm.TypeMismatch
      }
      let argv = if windows {
        []
      } else {
        guard self.process_args.get(i64(args[2])) is Some(entries) else {
          raise @vm.TypeMismatch
        }
        guard entries.all(entry => entry is Some(_)) else {
          raise @vm.TypeMismatch
        }
        entries
        .iter()
        .take_while(entry => entry is Some(_))
        .filter_map(entry => entry)
        .to_array()
      }
      let env = if legacy && !windows {
        guard env is Entries(entries) && entries.all(entry => entry is Some(_)) else {
          raise @vm.TypeMismatch
        }
        let inherited = i32(args[4])
        check_range(0, inherited, entries.length())
        let extra = entries[inherited:]
          .filter_map(entry => entry.unwrap().materialize())
          .map(entry => {
            let index = entry.find("=").unwrap_or(entry.length())
            (
              entry[:index].to_owned(),
              if index < entry.length() {
                entry[index + 1:].to_owned()
              } else {
                ""
              },
            )
          })
        process_environment(
          entries[:inherited].filter_map(entry => entry.unwrap().materialize()),
          extra,
        )
      } else {
        env.finish()
      }
      self.process_env.remove(i64(args[env_index]))
      if !windows {
        self.process_args.remove(i64(args[2]))
      }
      let base = if windows { 3 } else if legacy { 5 } else { 4 }
      let descriptors = Array::make(3, None)
      for index in 0..<3 {
        let handle = i64(args[base + index])
        if handle != 0L {
          guard self.fds.get(handle) is Some(fd) else { raise @vm.TypeMismatch }
          descriptors[index] = Some(fd)
        }
      }
      let cwd = if legacy && i32(args[base + 5]) != 0 {
        self.resolve(
          guest_string(caller, i32(args[base + 3]), i32(args[base + 4])),
        )
      } else {
        self.cwd
      }
      let spawn = GuestSpawn::{
        command,
        args: argv,
        env,
        stdio: descriptors,
        cwd,
        // The Unix ABI omits is_orphan, matching native async. Guest task
        // cancellation performs explicit kill; ending a run must preserve orphans.
        orphan: !windows || i32(args[if legacy { 10 } else { 6 }]) != 0,
        no_console: windows && legacy && i32(args[9]) != 0,
        child: None,
      }
      for fd in descriptors {
        if fd is Some(fd) {
          fd.retain()
        }
      }
      let result = self.new_job(() => self.spawn_child(spawn), cleanup=() => {
        for fd in descriptors {
          if fd is Some(fd) {
            fd.release()
          }
        }
      })
      guard result is [I64(handle)] && self.jobs.get(handle) is Some(job) else {
        raise @vm.TypeMismatch
      }
      job.spawn = Some(spawn)
      result
    }
    "thread_pool/spawn_job/set_cwd"
    | "thread_pool/spawn_job/set_no_console_window" => {
      guard self.jobs.get(i64(args[0])) is Some(job) &&
        !job.running &&
        job.result is None &&
        job.spawn is Some(spawn) else {
        raise @vm.TypeMismatch
      }
      if name == "thread_pool/spawn_job/set_cwd" {
        spawn.cwd = self.resolve(
          guest_string(caller, i32(args[1]), i32(args[2])),
        )
      } else {
        spawn.no_console = true
      }
      []
    }
    "thread_pool/spawn_job_get_result_handle"
    | "thread_pool/get_spawn_job_result_handle" => {
      guard self.jobs.get(i64(args[0])) is Some(job) &&
        job.spawn is Some(spawn) &&
        spawn.child is Some(child) else {
        return [I64(0L)]
      }
      if job.result_handle is Some(SpawnedProcess(handle)) {
        return [I64(handle)]
      }
      let handle = self.publish_child(child)
      job.result_handle = Some(SpawnedProcess(handle))
      [I64(handle)]
    }
    "process/open_pid_handle" => {
      let pid = i32(args[0])
      if self.children.get(pid) is Some(child) && !child.consumed {
        return [I64(self.publish_child(child))]
      }
      if self.policy is Some(_) {
        self.async_errno = if @async.platform is Windows { 5 } else { 13 }
        return [I64(0L)]
      }
      let native = open_native_process(pid)
      if !native_process_fd_valid(native) {
        self.async_errno = @os_error.get_errno()
        return [I64(0L)]
      }
      let handle = self.next_handle
      self.next_handle += 1L
      self.process_handles[handle] = External({ fd: native, references: 1, })
      [I64(handle)]
    }
    "thread_pool/make_wait_for_process_job" => {
      let pid = i32(args[1])
      let handle = i64(args[0])
      if self.policy is None &&
        (self.process_handles.get(handle) is Some(External(_)) || handle == 0L) &&
        !(self.children.get(pid) is Some(child) && !child.consumed) {
        let process = self.process_handles.get(handle)
        if process is Some(External(process)) {
          process.references += 1
        }
        return self.new_job(
          () => {
            let fd = match process {
              Some(External(process)) => process.fd
              _ => invalid_native_fd()
            }
            for ;; {
              let (ret, errno, status) = poll_process(fd, pid)
              if ret == 0 || !(errno is (11 | 35 | 997)) {
                return {
                  ret: if ret == 0 {
                    status
                  } else {
                    -1
                  },
                  errno,
                  data: b"",
                  opened: None,
                }
              }
              @async.sleep(1)
            }
          },
          cleanup=() => {
            if process is Some(External(process)) {
              process.release()
            }
          },
        )
      }
      guard self.children.get(pid) is Some(child) && !child.consumed else {
        raise @vm.TypeMismatch
      }
      guard (handle == 0L && !(@async.platform is Windows)) ||
        (
          self.process_handles.get(handle) is Some(Child(owner)) &&
          owner.identity == child.identity
        ) else {
        raise @vm.TypeMismatch
      }
      self.new_job(() => {
        while child.result is None {
          @async.sleep(1)
        }
        if child.consumed {
          return { ret: -1, errno: bad_fd_errno, data: b"", opened: None, }
        }
        if !(@async.platform is Windows) {
          child.consumed = true
          child.release_if_finished()
        }
        {
          ret: child.result.unwrap(),
          errno: child.error,
          data: b"",
          opened: None,
        }
      })
    }
    "process/get_process_result" => {
      let memory = guest_memory(caller)
      let pointer = i32(args[2]).reinterpret_as_uint().to_int64()
      if pointer + 4L > memory.byte_len() {
        self.async_errno = fault_errno
        return [I32(-1)]
      }
      let pid = i32(args[1])
      let handle = i64(args[0])
      if handle == 0L && @async.platform is Windows {
        self.async_errno = bad_fd_errno
        return [I32(-1)]
      }
      let child = if self.policy is None &&
        self.process_handles.get(handle) is Some(Child(child)) {
        Some(child)
      } else {
        self.children.get(pid)
      }
      let child = child.filter(child => {
        !child.consumed ||
        (
          @async.platform is Windows &&
          self.process_handles.get(handle) is Some(Child(owner)) &&
          owner.identity == child.identity
        )
      })
      if self.policy is None &&
        (self.process_handles.get(handle) is Some(External(_)) || child is None) {
        let fd = match self.process_handles.get(handle) {
          Some(External(process)) => process.fd
          None if handle == 0L && !(@async.platform is Windows) =>
            invalid_native_fd()
          _ => {
            self.async_errno = bad_fd_errno
            return [I32(-1)]
          }
        }
        let (result, errno, status) = poll_process(fd, pid)
        self.async_errno = errno
        if result == 0 {
          memory.store_i32(pointer.to_int(), status)
        }
        return [I32(result)]
      }
      guard child is Some(child) else {
        self.async_errno = if self.policy is Some(_) {
          if @async.platform is Windows {
            5
          } else {
            13
          }
        } else {
          bad_fd_errno
        }
        return [I32(-1)]
      }
      if i64(args[0]) != 0L &&
        !(self.process_handles.get(i64(args[0])) is Some(Child(handle)) &&
        handle.identity == child.identity) {
        self.async_errno = bad_fd_errno
        return [I32(-1)]
      }
      guard child.result is Some(result) else {
        self.async_errno = if @async.platform is Windows {
          997
        } else if @async.platform is MacOS {
          35
        } else {
          11
        }
        return [I32(-1)]
      }
      if child.error != 0 {
        self.async_errno = child.error
        return [I32(-1)]
      }
      memory.store_i32(pointer.to_int(), result)
      child.consumed = true
      child.release_if_finished()
      [I32(0)]
    }
    "process/kill" | "process/terminate" => {
      let pid = i32(args[0])
      let signal = if name == "process/kill" { -1 } else { i32(args[1]) }
      guard self.children.get(pid) is Some(child) && !child.consumed else {
        if self.policy is None {
          signal_process_pid(pid, signal)
          return []
        }
        return self.suspend(() => {
          self.deny("process signal")
          []
        })
      }
      if child.result is None {
        child_signal(child.native, signal)
      }
      []
    }
    "event_bus/register_pid" => {
      guard self.buses.get(i64(args[0])) is Some(bus) else {
        self.async_errno = bad_fd_errno
        return [I32(-1)]
      }
      let child = self.children.get(i32(args[1]))
      if self.policy is Some(_) && !(child is Some(child) && !child.consumed) {
        self.async_errno = if @async.platform is Windows { 5 } else { 13 }
        return [I32(-1)]
      }
      if child is Some(child) && child.result is Some(_) {
        return [I32(0)]
      }
      let result = register_child_pid(bus.native, i32(args[1]))
      if result < 0 {
        self.async_errno = @os_error.get_errno()
      }
      [I32(result)]
    }
    _ => raise @vm.UnknownImport("moonbitlang/async", name)
  }
}

///|
fn Host::publish_child(self : Host, child : GuestChild) -> Int64 {
  if child.closed {
    self.async_errno = bad_fd_errno
    return 0L
  }
  if @async.platform is MacOS {
    self.async_errno = 0
    return 0L
  }
  let handle = self.next_handle
  self.next_handle += 1L
  self.process_handles[handle] = Child(child)
  child.handles += 1
  handle
}

///|
extern "C" fn register_child_pid(bus : NativeEventBus, pid : Int32) -> Int32 = "moonrun_event_bus_register_pid"
