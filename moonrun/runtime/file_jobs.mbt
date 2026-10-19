///|
// Reuse native async's descriptor-stat ABI on the C-owned worker.
async fn packed_stat(
  fd : @types.Fd,
  request : Int32,
  capacity : Int32,
) -> Bytes {
  let length = stat_length(request, capacity)
  let result = run_native_job(StatFd, "", fd, request, length, false)
  guard result.ret >= 0 else {
    raise @os_error.OSError(result.errno, context="stat")
  }
  result.data
}

///|
async fn GuestFd::read_job(
  self : GuestFd,
  length : Int32,
  position : Int64,
  flags~ : Int32 = 0,
) -> JobResult {
  self.read_lock.acquire()
  defer self.read_lock.release()
  let buffer = FixedArray::make(length, b'\x00')
  let count = match self.owner {
    Socket(socket) => socket.read(buffer, flags)
    Pipe(pipe, true) => {
      if position != -1L {
        raise @os_error.OSError(
          if @async.platform is Windows {
            87
          } else {
            29
          },
          context="pipe read position",
        )
      }
      pipe.read(buffer)
    }
    Pipe(_, false) =>
      raise @os_error.OSError(bad_fd_errno, context="read from pipe writer")
    Standard(_, _) | Watcher(_) =>
      raise @os_error.OSError(bad_fd_errno, context="standard input adapter")
    File(file) =>
      if position == -1L {
        self.cursor_lock.acquire()
        defer self.cursor_lock.release()
        let count = file.read_at(buffer, position=self.cursor)
        self.cursor += count.to_int64()
        count
      } else {
        file.read_at(buffer, position~)
      }
  }
  {
    ret: count,
    errno: 0,
    data: Bytes::from_array(buffer[:count]),
    opened: None,
  }
}

///|
async fn GuestFd::write_job(
  self : GuestFd,
  data : Bytes,
  position : Int64,
  flags~ : Int32 = 0,
) -> JobResult {
  self.write_lock.acquire()
  defer self.write_lock.release()
  let count = match self.owner {
    Socket(socket) => socket.write(data, flags)
    Pipe(pipe, false) => {
      if position != -1L {
        raise @os_error.OSError(
          if @async.platform is Windows {
            87
          } else {
            29
          },
          context="pipe write position",
        )
      }
      pipe.write(data)
    }
    Pipe(_, true) =>
      raise @os_error.OSError(bad_fd_errno, context="write to pipe reader")
    Standard(_, _) | Watcher(_) =>
      raise @os_error.OSError(bad_fd_errno, context="standard output adapter")
    File(file) =>
      if position == -1L {
        self.cursor_lock.acquire()
        defer self.cursor_lock.release()
        let count = if self.append {
          file.write_once(data, offset=0, len=data.length())
        } else {
          file.write_at(data, position=self.cursor)
          data.length()
        }
        self.cursor = if self.append {
          file.size()
        } else {
          self.cursor + count.to_int64()
        }
        count
      } else {
        if self.append {
          raise @os_error.OSError(
            if @async.platform is Windows {
              87
            } else {
              22
            },
            context="positioned append write",
          )
        }
        file.write_at(data, position~)
        data.length()
      }
  }
  { ret: count, errno: 0, data: b"", opened: None, }
}

///|
fn Host::file_job_import(
  self : Host,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  match name {
    "thread_pool/make_statx_job" => {
      let path = guest_string(caller, i32(args[0]), i32(args[1]))
      let request = i32(args[2])
      let capacity = i32(args[3])
      let parent_handle = i64(args[4])
      let parent = if parent_handle == 0L {
        None
      } else {
        guard self.fds.get(parent_handle) is Some(parent) else {
          raise @vm.TypeMismatch
        }
        Some(parent)
      }
      let path = if parent is Some(_) { path } else { self.resolve(path) }
      let follow = i32(args[5]) != 0
      if parent is Some(fd) {
        fd.retain()
      }
      self.new_job(
        () => {
          let capacity = stat_length(request, capacity)
          self.authorize_at(path, parent, follow)
          run_native_job(
            StatPath,
            path,
            match parent {
              Some(fd) => fd.native()
              None => invalid_native_fd()
            },
            request,
            capacity,
            follow,
          )
        },
        cleanup=() => if parent is Some(fd) { fd.release() },
      )
    }
    "thread_pool/make_readdir_job" => {
      guard self.fds.get(i64(args[0])) is Some(fd) &&
        self.buffers.get(i64(args[1])) is Some(buffer) else {
        raise @vm.TypeMismatch
      }
      let length = i32(args[2])
      check_range(0, length, buffer.length())
      let restart = i32(args[3]) != 0
      fd.retain()
      self.new_job(
        () => {
          fd.cursor_lock.acquire()
          defer fd.cursor_lock.release()
          let result = run_native_job(
            ReadDirectory,
            "",
            fd.native(),
            0,
            length,
            restart,
          )
          if result.ret >= 0 {
            result.data.to_fixedarray().blit_to(buffer, len=length)
          }
          result
        },
        cleanup=() => fd.release(),
      )
    }
    "thread_pool/make_read_job" | "thread_pool/make_write_job" => {
      guard self.fds.get(i64(args[0])) is Some(fd) else {
        raise @vm.TypeMismatch
      }
      let reading = name == "thread_pool/make_read_job"
      let length = i32(args[if reading { 1 } else { 3 }])
      let position = i64(args[if reading { 2 } else { 4 }])
      guard length >= 0 && position >= -1L else {
        raise @vm.OutOfBoundsMemoryAccess
      }
      let data = if reading {
        b""
      } else {
        let pointer = i32(args[1]).reinterpret_as_uint().to_int64() +
          i32(args[2]).reinterpret_as_uint().to_int64()
        guard pointer <= 0xFFFF_FFFFL else { raise @vm.OutOfBoundsMemoryAccess }
        guest_bytes(caller, pointer.to_int(), length)
      }
      fd.retain()
      self.new_job(
        () => {
          if reading {
            self.read_fd(fd, length, position)
          } else {
            self.write_fd(fd, data, position)
          }
        },
        cleanup=() => fd.release(),
      )
    }
    "thread_pool/make_open_stat_job" | "thread_pool/make_open_job" => {
      let path = self.resolve(guest_string(caller, i32(args[0]), i32(args[1])))
      let access = i32(args[2])
      let create = i32(args[3])
      let append = i32(args[4]) != 0
      let sync = i32(args[5])
      let permission = i32(args[6])
      let request = if name == "thread_pool/make_open_job" {
        13
      } else {
        i32(args[7])
      }
      let capacity = if name == "thread_pool/make_open_job" {
        32
      } else {
        i32(args[8])
      }
      self.new_job(() => {
        let invalid = if @async.platform is Windows { 87 } else { 22 }
        self.authorize_path(
          path,
          read=access is (0 | 2 | 3),
          write=access is (1 | 2) || create != 0 || append,
        )
        if (request & -14) != 0 {
          self.authorize_path(path)
        }
        if path.contains_char('\u0000') {
          raise @os_error.OSError(invalid, context="open path")
        }
        if access == 3 && @async.platform is Windows {
          let result = run_native_job(
            OpenWatcher,
            path,
            invalid_native_fd(),
            0,
            0,
            false,
          )
          if result.ret < 0 {
            raise @os_error.OSError(
              result.errno,
              context="open directory watcher",
            )
          }
          guard result.opened is Some(fd) else { raise @vm.TypeMismatch }
          errdefer fd.release()
          fd.path = Some(@fs.realpath(path))
          let data = packed_stat(fd.native(), request, capacity)
          return { ret: 0, errno: 0, data, opened: Some(fd), }
        }
        let mode : @fs.Mode = match access {
          0 => ReadOnly
          1 => WriteOnly
          2 => ReadWrite
          _ => raise @os_error.OSError(invalid, context="open access")
        }
        let create_mode : @fs.CreateMode = match create {
          0 => OpenExisting
          1 => TruncateExisting
          2 => OpenOrCreate
          3 => CreateOrTruncate
          4 => CreateNew
          _ => raise @os_error.OSError(invalid, context="open create mode")
        }
        let sync : @fs.SyncMode = match sync {
          0 => NoSync
          1 => Data
          2 => Full
          _ => raise @os_error.OSError(invalid, context="open sync mode")
        }
        let file = @fs.open(
          path,
          mode~,
          create_mode~,
          append~,
          sync~,
          permission~,
        )
        errdefer file.close()
        let stat = packed_stat(file.fd(), request, capacity)
        {
          ret: 0,
          errno: 0,
          data: stat,
          opened: Some(
            GuestFd(
              File(file),
              append~,
              path=if self.policy is Some(_) {
                @fs.realpath(path)
              } else {
                path
              },
            ),
          ),
        }
      })
    }
    "thread_pool/open_job_get_fd" => {
      if self.jobs.get(i64(args[0])) is Some(job) &&
        job.result_handle is Some(OpenedFile(handle)) {
        return [I64(handle)]
      }
      guard self.jobs.get(i64(args[0])) is Some(job) &&
        job.result is Some(result) &&
        result.ret >= 0 &&
        result.opened is Some(fd) else {
        raise @vm.TypeMismatch
      }
      let handle = self.next_handle
      self.next_handle += 1L
      result.opened = None
      self.fds[handle] = fd
      job.result_handle = Some(OpenedFile(handle))
      [I64(handle)]
    }
    "thread_pool/get_read_result" | "thread_pool/get_stat_result" => {
      guard self.jobs.get(i64(args[0])) is Some(job) &&
        job.result is Some(result) &&
        !job.running else {
        raise @vm.TypeMismatch
      }
      let pointer = i32(args[1]).reinterpret_as_uint().to_int64()
      let address = pointer +
        (if name == "thread_pool/get_read_result" {
          i32(args[2]).reinterpret_as_uint().to_int64()
        } else {
          0L
        })
      let length = i32(
        args[if name == "thread_pool/get_read_result" { 3 } else { 2 }],
      )
      let memory = guest_memory(caller)
      guard length >= 0 &&
        address <= 0xFFFF_FFFFL &&
        address + length.to_int64() <= memory.byte_len() else {
        raise @vm.OutOfBoundsMemoryAccess
      }
      let count = @cmp.minimum(length, result.data.length())
      memory.init_data_at(address, result.data[:count].to_owned())
      []
    }
    "thread_pool/make_fstatx_job"
    | "thread_pool/make_fsync_job"
    | "thread_pool/make_flock_job" => {
      guard self.fds.get(i64(args[0])) is Some(fd) else {
        raise @vm.TypeMismatch
      }
      let value = i32(args[1])
      let capacity = if name == "thread_pool/make_fstatx_job" {
        i32(args[2])
      } else {
        0
      }
      fd.retain()
      self.new_job(
        () => {
          let data = if name == "thread_pool/make_fstatx_job" {
            self.authorize_resource(fd, false)
            packed_stat(fd.native(), value, capacity)
          } else {
            guard fd.owner is File(file) else {
              raise @os_error.OSError(bad_fd_errno, context="file job")
            }
            if name == "thread_pool/make_fsync_job" {
              file.sync(only_data=value != 0)
            } else {
              if value != 0 {
                self.authorize_resource(fd, true)
              }
              file.lock(if value != 0 { Exclusive } else { Shared })
            }
            b""
          }
          { ret: 0, errno: 0, data, opened: None, }
        },
        cleanup=() => fd.release(),
      )
    }
    _ => self.path_job_import(caller, name, args)
  }
}
