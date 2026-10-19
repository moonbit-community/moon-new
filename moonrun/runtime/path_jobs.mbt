///|
fn Host::path_job_import(
  self : Host,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  match name {
    "thread_pool/make_remove_job"
    | "thread_pool/make_rmdir_job"
    | "thread_pool/make_mkdir_job"
    | "thread_pool/make_chmod_job"
    | "thread_pool/make_access_job"
    | "thread_pool/make_realpath_job" => {
      let path = self.resolve(guest_string(caller, i32(args[0]), i32(args[1])))
      let value = if args.length() > 2 { i32(args[2]) } else { 0 }
      self.new_job(() => {
        let write = name != "thread_pool/make_realpath_job" &&
          (name != "thread_pool/make_access_job" || value == 2)
        self.authorize_path(
          path,
          read=!write,
          write~,
          entry=name == "thread_pool/make_remove_job" ||
            name == "thread_pool/make_rmdir_job" ||
            name == "thread_pool/make_mkdir_job",
        )
        let mut data = b""
        let mut ret = 0
        let mut errno = 0
        if path.contains_char('\u0000') {
          raise @os_error.OSError(
            if @async.platform is Windows {
              87
            } else {
              22
            },
            context="path",
          )
        }
        match name {
          "thread_pool/make_remove_job" => @fs.remove(path)
          "thread_pool/make_rmdir_job" => @fs.rmdir(path)
          "thread_pool/make_mkdir_job" => @fs.mkdir(path, permission=value)
          "thread_pool/make_chmod_job" => @fs.chmod(path, value)
          "thread_pool/make_realpath_job" => {
            let resolved = @fs.realpath(path)
            data = if @async.platform is Windows {
              @utf16.encode(resolved, endianness=Little, bom=false) +
              b"\x00\x00"
            } else {
              @utf8.encode(resolved) + b"\x00"
            }
          }
          "thread_pool/make_access_job" => {
            let allowed = match value {
              0 => @fs.exists(path)
              1 => @fs.can_read(path)
              2 => @fs.can_write(path)
              3 => @fs.can_execute(path)
              _ =>
                raise @os_error.OSError(
                  if @async.platform is Windows {
                    87
                  } else {
                    22
                  },
                  context="access mode",
                )
            }
            if !allowed {
              ret = -1
              errno = if @fs.exists(path) {
                if @async.platform is Windows {
                  5
                } else {
                  13
                }
              } else {
                2
              }
            }
          }
          _ => ()
        }
        { ret, errno, data, opened: None, }
      })
    }
    "thread_pool/make_rename_job" | "thread_pool/make_symlink_job" => {
      let first = guest_string(caller, i32(args[0]), i32(args[1]))
      let second = self.resolve(
        guest_string(caller, i32(args[2]), i32(args[3])),
      )
      let flag = i32(args[4]) != 0
      self.new_job(() => {
        if first.contains_char('\u0000') || second.contains_char('\u0000') {
          raise @os_error.OSError(
            if @async.platform is Windows {
              87
            } else {
              22
            },
            context="path",
          )
        }
        if name == "thread_pool/make_rename_job" {
          self.authorize_path(
            self.resolve(first),
            read=false,
            write=true,
            entry=true,
          )
          self.authorize_path(second, read=false, write=true, entry=true)
          @fs.rename(self.resolve(first), second, replace=flag)
        } else {
          self.authorize_path(second, read=false, write=true, entry=true)
          @fs.symlink(target=first, second, force_symlink=flag)
        }
        { ret: 0, errno: 0, data: b"", opened: None, }
      })
    }
    "thread_pool/get_realpath_result" => {
      guard self.jobs.get(i64(args[0])) is Some(job) &&
        !job.running &&
        job.result is Some(result) &&
        result.ret >= 0 else {
        raise @vm.TypeMismatch
      }
      let handle = self.next_handle
      self.next_handle += 1L
      self.buffers[handle] = result.data.to_fixedarray()
      [I64(handle)]
    }
    _ => raise @vm.UnknownImport("moonbitlang/async", name)
  }
}

///|
fn file_job_signature(name : String) -> @wasm.FuncType? {
  let (params, results) : (
    ReadOnlyArray[@wasm.ValueType],
    ReadOnlyArray[@wasm.ValueType],
  ) = match name {
    "thread_pool/make_statx_job" => ([I32, I32, I32, I32, I64, I32], [I64])
    "thread_pool/make_readdir_job" => ([I64, I64, I32, I32], [I64])
    "thread_pool/make_read_job" => ([I64, I32, I64], [I64])
    "thread_pool/make_write_job" => ([I64, I32, I32, I32, I64], [I64])
    "thread_pool/make_open_stat_job" =>
      ([I32, I32, I32, I32, I32, I32, I32, I32, I32], [I64])
    "thread_pool/make_open_job" => ([I32, I32, I32, I32, I32, I32, I32], [I64])
    "thread_pool/open_job_get_fd" | "thread_pool/get_realpath_result" =>
      ([I64], [I64])
    "thread_pool/get_read_result" => ([I64, I32, I32, I32], [])
    "thread_pool/get_stat_result" => ([I64, I32, I32], [])
    "thread_pool/make_fstatx_job" => ([I64, I32, I32], [I64])
    "thread_pool/make_fsync_job" | "thread_pool/make_flock_job" =>
      ([I64, I32], [I64])
    "thread_pool/make_remove_job"
    | "thread_pool/make_rmdir_job"
    | "thread_pool/make_realpath_job" => ([I32, I32], [I64])
    "thread_pool/make_mkdir_job"
    | "thread_pool/make_chmod_job"
    | "thread_pool/make_access_job" => ([I32, I32, I32], [I64])
    "thread_pool/make_rename_job" | "thread_pool/make_symlink_job" =>
      ([I32, I32, I32, I32, I32], [I64])
    _ => return None
  }
  Some({ params, results, })
}
