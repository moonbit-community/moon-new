///|
fn Context::file_job_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.async_host
  match name {
    "thread_pool/make_statx_job" => {
      let path = guest_string(caller, i32(args[0]), i32(args[1]))
      let request = i32(args[2])
      let capacity = i32(args[3])
      let parent_handle = i64(args[4])
      let parent = if parent_handle == 0L {
        None
      } else {
        guard host.fds.get(parent_handle) is Some(parent) else {
          raise @vm.TypeMismatch
        }
        Some(parent)
      }
      let path = if parent is Some(_) {
        path
      } else {
        self.runtime.filesystem.resolve(path)
      }
      let follow = i32(args[5]) != 0
      if parent is Some(fd) {
        fd.retain()
      }
      [
        I64(
          host.new_job(
            () => {
              @fs_job.stat(
                self.runtime.filesystem,
                path,
                parent,
                follow,
                request,
                capacity,
              )
            },
            cleanup=() => if parent is Some(fd) { fd.release() },
          ),
        ),
      ]
    }
    "thread_pool/make_readdir_job" => {
      guard host.fds.get(i64(args[0])) is Some(fd) &&
        host.buffers.get(i64(args[1])) is Some(buffer) else {
        raise @vm.TypeMismatch
      }
      let length = i32(args[2])
      @sys.check_range(0, length, buffer.length())
      let restart = i32(args[3]) != 0
      fd.retain()
      [
        I64(
          host.new_job(
            () => @fs_job.read_directory(fd, buffer, length, restart),
            cleanup=() => fd.release(),
          ),
        ),
      ]
    }
    "thread_pool/make_read_job" | "thread_pool/make_write_job" => {
      guard host.fds.get(i64(args[0])) is Some(fd) else {
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
      [
        I64(
          host.new_job(
            () => {
              if reading {
                self.runtime.stdio.read_fd(fd, length, position)
              } else {
                self.runtime.stdio.write_fd(fd, data, position)
              }
            },
            cleanup=() => fd.release(),
          ),
        ),
      ]
    }
    "thread_pool/make_open_stat_job" | "thread_pool/make_open_job" => {
      let path = self.runtime.filesystem.resolve(
        guest_string(caller, i32(args[0]), i32(args[1])),
      )
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
      [
        I64(
          host.new_job(() => {
            @fs_job.open(
              self.runtime.filesystem,
              path,
              access,
              create,
              append,
              sync,
              permission,
              request,
              capacity,
            )
          }),
        ),
      ]
    }
    "thread_pool/open_job_get_fd" => [I64(host.open_job_fd(i64(args[0])))]
    "thread_pool/get_read_result" | "thread_pool/get_stat_result" => {
      guard host.jobs.get(i64(args[0])) is Some(job) &&
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
      guard host.fds.get(i64(args[0])) is Some(fd) else {
        raise @vm.TypeMismatch
      }
      let value = i32(args[1])
      let capacity = if name == "thread_pool/make_fstatx_job" {
        i32(args[2])
      } else {
        0
      }
      fd.retain()
      [
        I64(
          host.new_job(
            () => {
              @fs_job.resource_job(
                self.runtime.filesystem,
                fd,
                if name == "thread_pool/make_fstatx_job" {
                  Stat
                } else if name == "thread_pool/make_fsync_job" {
                  Sync
                } else {
                  Lock
                },
                value,
                capacity,
              )
            },
            cleanup=() => fd.release(),
          ),
        ),
      ]
    }
    _ => self.path_job_import(caller, name, args)
  }
}
