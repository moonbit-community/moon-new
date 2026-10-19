///|
fn legacy_async_signature(name : String) -> @wasm.FuncType? {
  let (params, results) : (
    ReadOnlyArray[@wasm.ValueType],
    ReadOnlyArray[@wasm.ValueType],
  ) = match name {
    "random/fill" => ([I32, I32], [I32])
    "fd_util/sizeof_file_time" => ([], [I32])
    "fd_util/get_atime_sec"
    | "fd_util/get_mtime_sec"
    | "fd_util/get_ctime_sec" => ([I32], [I64])
    "fd_util/get_atime_nsec"
    | "fd_util/get_mtime_nsec"
    | "fd_util/get_ctime_nsec" => ([I32], [I32])
    "fd_util/set_nonblocking/unix" | "fs/unlock_file" => ([I64], [I32])
    "fs/try_lock_file" => ([I64, I32], [I32])
    "fs/errno_is_lock_violation" => ([I32], [I32])
    "event_bus/register" => ([I64, I64, I32], [I32])
    "thread_pool/make_file_kind_by_path_job" => ([I64, I32, I32, I32], [I64])
    "thread_pool/make_file_time_by_path_job" => ([I32, I32, I32], [I64])
    "thread_pool/make_file_size_job" | "thread_pool/make_file_time_job" =>
      ([I64], [I64])
    "thread_pool/get_file_size_result"
    | "thread_pool/open_job_get_dev_id"
    | "thread_pool/open_job_get_file_id" => ([I64], [I64])
    "thread_pool/open_job_get_kind" => ([I64], [I32])
    "thread_pool/get_file_time_result" => ([I64, I32], [])
    "thread_pool/run_job" => ([I64], [])
    "thread_pool/spawn_worker_with_pipe" => ([I32, I64, I64], [I64])
    "thread_pool/make_sigwait_job" => ([I32, I32], [I64])
    _ => return None
  }
  Some({ params, results, })
}

///|
extern "C" fn fd_nonblocking(fd : @types.Fd) -> Int32 = "moonrun_fd_nonblocking"

///|
fn Host::legacy_async_import(
  self : Host,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  match name {
    "random/fill" => {
      let pointer = i32(args[0]).reinterpret_as_uint().to_int64()
      let length = i32(args[1])
      let memory = guest_memory(caller)
      guard length >= 0 && pointer + length.to_int64() <= memory.byte_len() else {
        self.async_errno = fault_errno
        return [I32(-1)]
      }
      let buffer = FixedArray::make(length, b'\x00')
      guard @wasi.native_getrandom(buffer, length) else {
        self.async_errno = @os_error.get_errno()
        return [I32(-1)]
      }
      memory.init_data_at(pointer, Bytes::from_array(buffer))
      [I32(0)]
    }
    "fd_util/sizeof_file_time" => [I32(48)]
    name if name.has_prefix("fd_util/get_") => {
      let data = guest_bytes(caller, i32(args[0]), 48).to_fixedarray()
      let offset = if name.contains("atime") {
        0
      } else if name.contains("mtime") {
        16
      } else {
        32
      }
      if name.has_suffix("_sec") {
        [I64(buffer_word(data, offset, 8))]
      } else {
        [I32(buffer_word(data, offset + 8, 4).to_int())]
      }
    }
    "event_bus/register" => {
      let result = self.event_bus_import("event_bus/try_register", args)
      match result {
        [I32(1)] => [I32(0)]
        [I32(0)] => {
          self.async_errno = if @async.platform is Windows {
            50
          } else if @async.platform is MacOS {
            45
          } else {
            95
          }
          [I32(-1)]
        }
        _ => result
      }
    }
    "fd_util/set_nonblocking/unix" => {
      guard self.fds.get(i64(args[0])) is Some(fd) else {
        self.async_errno = bad_fd_errno
        return [I32(-1)]
      }
      self.socket_status(fd_nonblocking(fd.native()))
    }
    "fs/errno_is_lock_violation" =>
      [
        I32(
          if i32(args[0]) ==
            (if @async.platform is Windows {
              33
            } else if @async.platform is MacOS {
              35
            } else {
              11
            }) {
            1
          } else {
            0
          },
        ),
      ]
    "fs/try_lock_file" | "fs/unlock_file" => {
      guard self.fds.get(i64(args[0])) is Some(fd) && fd.owner is File(file) else {
        self.async_errno = bad_fd_errno
        return [I32(-1)]
      }
      let exclusive = name == "fs/try_lock_file" && i32(args[1]) != 0
      self.suspend(() => {
        try {
          if exclusive {
            self.authorize_resource(fd, true)
          }
          if name == "fs/unlock_file" {
            file.unlock()
          } else if !file.try_lock(
              if i32(args[1]) != 0 {
                Exclusive
              } else {
                Shared
              },
            ) {
            self.async_errno = if @async.platform is Windows {
              33
            } else if @async.platform is MacOS {
              35
            } else {
              11
            }
            return [I32(-1)]
          }
          [I32(0)]
        } catch {
          @os_error.OSError(code, ..) => {
            self.async_errno = code
            [I32(-1)]
          }
          error => raise @vm.LinkErrorDetail("file lock: \{error}")
        }
      })
    }
    "thread_pool/make_file_kind_by_path_job"
    | "thread_pool/make_file_time_by_path_job" => {
      let kind = name == "thread_pool/make_file_kind_by_path_job"
      let base = if kind { 1 } else { 0 }
      let path = guest_string(caller, i32(args[base]), i32(args[base + 1]))
      let follow = i32(args[base + 2]) != 0
      let parent = if kind && i64(args[0]) != 0L {
        guard self.fds.get(i64(args[0])) is Some(fd) else {
          raise @vm.TypeMismatch
        }
        Some(fd)
      } else {
        None
      }
      let path = if parent is Some(_) { path } else { self.resolve(path) }
      if parent is Some(fd) {
        fd.retain()
      }
      self.new_job(
        () => {
          self.authorize_at(path, parent, follow)
          let result = run_native_job(
            StatPath,
            path,
            parent.map(fd => fd.native()).unwrap_or_else(invalid_native_fd),
            if kind {
              1
            } else {
              112
            },
            if kind {
              16
            } else {
              56
            },
            follow,
          )
          {
            ..result,
            ret: if kind && result.ret >= 0 {
              buffer_word(result.data.to_fixedarray(), 8, 8).to_int()
            } else {
              result.ret
            },
          }
        },
        cleanup=() => if parent is Some(fd) { fd.release() },
      )
    }
    "thread_pool/make_file_size_job" | "thread_pool/make_file_time_job" => {
      guard self.fds.get(i64(args[0])) is Some(fd) else {
        raise @vm.TypeMismatch
      }
      let size = name == "thread_pool/make_file_size_job"
      fd.retain()
      self.new_job(
        () => {
          self.authorize_resource(fd, false)
          let data = packed_stat(
            fd.native(),
            if size {
              2
            } else {
              112
            },
            if size {
              16
            } else {
              56
            },
          )
          { ret: 0, errno: 0, data, opened: None, }
        },
        cleanup=() => fd.release(),
      )
    }
    "thread_pool/open_job_get_kind"
    | "thread_pool/open_job_get_dev_id"
    | "thread_pool/open_job_get_file_id"
    | "thread_pool/get_file_size_result"
    | "thread_pool/get_file_time_result" => {
      guard self.jobs.get(i64(args[0])) is Some(job) &&
        !job.running &&
        job.result is Some(result) &&
        result.errno == 0 else {
        raise @vm.TypeMismatch
      }
      let data = result.data.to_fixedarray()
      if name == "thread_pool/get_file_time_result" {
        check_range(8, 48, data.length())
        let pointer = i32(args[1]).reinterpret_as_uint().to_int64()
        guard pointer + 48L <= guest_memory(caller).byte_len() else {
          raise @vm.OutOfBoundsMemoryAccess
        }
        guest_memory(caller).init_data_at(
          pointer,
          Bytes::from_array(data[8:56]),
        )
        return []
      }
      let offset = if name == "thread_pool/open_job_get_dev_id" {
        16
      } else if name == "thread_pool/open_job_get_file_id" {
        24
      } else {
        8
      }
      let value = buffer_word(data, offset, 8)
      if name == "thread_pool/open_job_get_kind" {
        [I32(value.to_int())]
      } else {
        [I64(value)]
      }
    }
    "thread_pool/run_job" => {
      guard self.jobs.get(i64(args[0])) is Some(job) else {
        raise @vm.TypeMismatch
      }
      self.suspend(() => {
        guard !job.running && job.result is None else { raise @vm.TypeMismatch }
        job.running = true
        defer {
          job.running = false
        }
        job.result = Some(
          (job.action)() catch {
            @os_error.OSError(code, ..) =>
              { ret: -1, errno: code, data: b"", opened: None, }
            error => raise error
          },
        )
        []
      })
    }
    "thread_pool/spawn_worker_with_pipe" =>
      self.worker_import(caller, name, args)
    "thread_pool/make_sigwait_job" => self.legacy_signal_job(caller, args)
    _ => raise @vm.UnknownImport("moonbitlang/async", name)
  }
}
