///|
fn Context::path_job_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.async_host
  match name {
    "thread_pool/make_remove_job"
    | "thread_pool/make_rmdir_job"
    | "thread_pool/make_mkdir_job"
    | "thread_pool/make_chmod_job"
    | "thread_pool/make_access_job"
    | "thread_pool/make_realpath_job" => {
      let path = self.runtime.filesystem.resolve(
        guest_string(caller, i32(args[0]), i32(args[1])),
      )
      let value = if args.length() > 2 { i32(args[2]) } else { 0 }
      [
        I64(
          host.new_job(() => {
            @fs_job.path_job(
              self.runtime.filesystem,
              match name {
                "thread_pool/make_remove_job" => @fs_job.Remove
                "thread_pool/make_rmdir_job" => @fs_job.RemoveDirectory
                "thread_pool/make_mkdir_job" => @fs_job.CreateDirectory
                "thread_pool/make_chmod_job" => @fs_job.Chmod
                "thread_pool/make_access_job" => @fs_job.Access
                "thread_pool/make_realpath_job" => @fs_job.Realpath
                _ => raise @vm.UnknownImport("moonbitlang/async", name)
              },
              path,
              value,
            )
          }),
        ),
      ]
    }
    "thread_pool/make_rename_job" | "thread_pool/make_symlink_job" => {
      let first = guest_string(caller, i32(args[0]), i32(args[1]))
      let second = self.runtime.filesystem.resolve(
        guest_string(caller, i32(args[2]), i32(args[3])),
      )
      let flag = i32(args[4]) != 0
      [
        I64(
          host.new_job(() => {
            @fs_job.rename_or_symlink(
              self.runtime.filesystem,
              name == "thread_pool/make_rename_job",
              first,
              second,
              flag,
            )
          }),
        ),
      ]
    }
    "thread_pool/get_realpath_result" => {
      guard host.jobs.get(i64(args[0])) is Some(job) &&
        !job.running &&
        job.result is Some(result) &&
        result.ret >= 0 else {
        raise @vm.TypeMismatch
      }
      let handle = self.runtime.handles.allocate()
      host.buffers[handle] = result.data.to_fixedarray()
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
