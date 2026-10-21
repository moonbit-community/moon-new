///|
fn Context::inherited_process_env(self : Context) -> Array[String] {
  self.runtime.env
  .iter()
  .map(pair => {
    let (key, value) = pair
    "\{key}=\{value}"
  })
  .to_array()
}

///|
fn Context::put_process_env(
  self : Context,
  env : @process.Environment,
) -> Array[@wasm.Value] {
  let handle = self.runtime.handles.allocate()
  self.runtime.process.process_env[handle] = env
  [I64(handle)]
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
fn Context::process_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.async_host
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
        if @sys.platform is Windows {
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
        if @sys.platform is Windows {
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
      let handle = self.runtime.handles.allocate()
      self.runtime.process.process_args[handle] = Array::make(length, None)
      [I64(handle)]
    }
    "process/argv_array_add_entry/unix"
    | "process/argv_array_add_encoded_entry/unix" => {
      guard self.runtime.process.process_args.get(i64(args[0])) is Some(entries) else {
        raise @vm.TypeMismatch
      }
      let index = i32(args[1])
      @sys.check_range(index, 1, entries.length())
      // OsString and String both cross the guest boundary as UTF-16.
      entries[index] = Some(guest_string(caller, i32(args[2]), i32(args[3])))
      []
    }
    "process/env_add_entry" | "process/env_block_add_entry" => {
      guard self.runtime.process.process_env.get(i64(args[0])) is Some(env) else {
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
          @sys.check_range(index, 1, entries.length())
          entries[index] = Some(Added(key, value))
        }
        Wide(buffer) => {
          if key.contains_char('\u0000') {
            return []
          }
          let data = @utf16.encode(
            "\{key}=\{@process.truncate_nul(value)}\u0000",
            endianness=Little,
            bom=false,
          )
          let offset = i32(args[1]) * 2
          @sys.check_range(offset, data.length(), buffer.length())
          data
          .to_fixedarray()
          .blit_to(buffer, dst_offset=offset, len=data.length())
        }
      }
      []
    }
    "process/env_block_length" => {
      guard self.runtime.process.process_env.get(i64(args[0])) is Some(env) else {
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
      guard self.runtime.process.process_env.get(i64(args[0])) is Some(dst) &&
        self.runtime.process.process_env.get(i64(args[1])) is Some(src) else {
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
          @sys.check_range(offset, remaining.length(), entries.length())
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
            @process.process_environment(inherited, extra).join("\u0000") +
            "\u0000",
            endianness=Little,
            bom=false,
          )
          @sys.check_range(0, data.length(), buffer.length())
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
      guard windows == (@sys.platform is Windows) else {
        raise @vm.UnknownImport("moonbitlang/async", name)
      }
      let legacy = name.has_prefix("thread_pool/make_spawn_job/")
      let command = guest_string(caller, i32(args[0]), i32(args[1]))
      let env_index = if windows { 2 } else { 3 }
      guard self.runtime.process.process_env.get(i64(args[env_index]))
        is Some(env) else {
        raise @vm.TypeMismatch
      }
      let argv = if windows {
        []
      } else {
        guard self.runtime.process.process_args.get(i64(args[2]))
          is Some(entries) else {
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
        @sys.check_range(0, inherited, entries.length())
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
        @process.process_environment(
          entries[:inherited].filter_map(entry => entry.unwrap().materialize()),
          extra,
        )
      } else {
        env.finish()
      }
      self.runtime.process.process_env.remove(i64(args[env_index]))
      if !windows {
        self.runtime.process.process_args.remove(i64(args[2]))
      }
      let base = if windows { 3 } else if legacy { 5 } else { 4 }
      let descriptors = Array::make(3, None)
      for index in 0..<3 {
        let handle = i64(args[base + index])
        if handle != self.runtime.handles.invalid_fd {
          guard host.fds.get(handle) is Some(fd) else {
            raise @sys.Operation("Badf: invalid spawn stdio handle")
          }
          descriptors[index] = Some(fd)
        }
      }
      let cwd = if legacy && i32(args[base + 5]) != 0 {
        self.runtime.filesystem.resolve(
          guest_string(caller, i32(args[base + 3]), i32(args[base + 4])),
        )
      } else {
        self.runtime.cwd
      }
      let spawn = @process.SpawnOptions::{
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
      [I64(host.new_spawn_job(self.runtime.process, spawn))]
    }
    "thread_pool/spawn_job/set_cwd"
    | "thread_pool/spawn_job/set_no_console_window" => {
      guard host.jobs.get(i64(args[0])) is Some(job) &&
        !job.running &&
        job.result is None &&
        job.spawn is Some(spawn) else {
        raise @vm.TypeMismatch
      }
      if name == "thread_pool/spawn_job/set_cwd" {
        spawn.cwd = self.runtime.filesystem.resolve(
          guest_string(caller, i32(args[1]), i32(args[2])),
        )
      } else {
        spawn.no_console = true
      }
      []
    }
    "thread_pool/spawn_job_get_result_handle"
    | "thread_pool/get_spawn_job_result_handle" => {
      let handle = host.spawn_job_result(self.runtime.process, i64(args[0])) catch {
        @sys.OSError(code, ..) => {
          host.async_errno = code
          self.runtime.handles.null_handle
        }
        error => raise error
      }
      [I64(handle)]
    }
    "process/open_pid_handle" => {
      let pid = i32(args[0])
      let handle = self.runtime.process.open_pid_handle(pid) catch {
        @sys.OSError(code, ..) => {
          host.async_errno = code
          return [I64(self.runtime.handles.invalid_fd)]
        }
      }
      if handle == self.runtime.handles.invalid_fd {
        // Unix may successfully fall back to PID-based waiting. Native async
        // clears errno to distinguish this case from a failed open.
        host.async_errno = 0
      }
      [I64(handle)]
    }
    "thread_pool/make_wait_for_process_job" => {
      let pid = i32(args[1])
      let handle = i64(args[0])
      if self.runtime.policy is None &&
        (
          self.runtime.process.process_handles.get(handle) is Some(External(_)) ||
          handle == self.runtime.handles.invalid_fd
        ) &&
        !(self.runtime.process.children.get(pid) is Some(child) &&
        !child.consumed) {
        let process = self.runtime.process.process_handles.get(handle)
        if process is Some(External(process)) {
          process.retain()
        }
        return [
          I64(
            host.new_job(() => @process.wait_external(process, pid), cleanup=() => {
              if process is Some(External(process)) {
                process.release()
              }
            }),
          ),
        ]
      }
      guard self.runtime.process.children.get(pid) is Some(child) &&
        !child.consumed else {
        raise @vm.TypeMismatch
      }
      guard (
          handle == self.runtime.handles.invalid_fd &&
          !(@sys.platform is Windows)
        ) ||
        (
          self.runtime.process.process_handles.get(handle)
          is Some(@process.Child(owner)) &&
          owner.identity == child.identity
        ) else {
        raise @vm.TypeMismatch
      }
      [I64(host.new_job(() => child.wait()))]
    }
    "process/get_process_result" => {
      let memory = guest_memory(caller)
      let pointer = i32(args[2]).reinterpret_as_uint().to_int64()
      if pointer + 4L > memory.byte_len() {
        host.async_errno = @sys.fault_errno
        return [I32(-1)]
      }
      let pid = i32(args[1])
      let handle = i64(args[0])
      let status = Some(self.runtime.process.get_result(handle, pid)) catch {
        @sys.OSError(code, ..) => {
          host.async_errno = code
          None
        }
      }
      match status {
        Some(status) => {
          memory.store_i32(pointer.to_int(), status)
          [I32(0)]
        }
        None => [I32(-1)]
      }
    }
    "process/kill" | "process/terminate" => {
      let pid = i32(args[0])
      let signal = if name == "process/kill" { -1 } else { i32(args[1]) }
      self.runtime.process.signal(pid, signal)
      []
    }
    "event_bus/register_pid" => {
      guard host.buses.get(i64(args[0])) is Some(bus) else {
        host.async_errno = @sys.bad_fd_errno
        return [I32(-1)]
      }
      let child = self.runtime.process.children.get(i32(args[1]))
      if self.runtime.policy is Some(_) &&
        !(child is Some(child) && !child.consumed) {
        host.async_errno = if @sys.platform is Windows { 5 } else { 13 }
        return [I32(-1)]
      }
      if child is Some(child) && child.result is Some(_) {
        return [I32(0)]
      }
      let result = @sys.register_child_pid(bus.native, i32(args[1]))
      if result < 0 {
        host.async_errno = @sys.get_errno()
      }
      [I32(result)]
    }
    _ => raise @vm.UnknownImport("moonbitlang/async", name)
  }
}
