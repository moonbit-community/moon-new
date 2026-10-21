///|
fn Context::sqlite_job(
  self : Context,
  handle : Int64,
) -> @sqlite.Job raise @sqlite.SqliteError {
  guard self.runtime.async_host.jobs.get(handle) is Some(job) &&
    job.sqlite is Some(sqlite) else {
    raise @sqlite.InvalidHandle
  }
  guard !job.running else { raise @sqlite.Fault }
  sqlite
}

///|
fn Context::sqlite_job_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.sqlite
  let job = match name {
    "sqlite3_make_open_job" =>
      host.make_open_job(
        sqlite_filename(caller, i32(args[0]), i32(args[1])),
        i32(args[2]),
      )
    "sqlite3_make_prepare_job" =>
      host.make_prepare_job(
        i64(args[0]),
        sqlite_string(caller, i32(args[1]), i32(args[2]), i32(args[3])),
      )
    "sqlite3_make_step_job" => host.make_step_job(i64(args[0]), i64(args[1]))
    "sqlite3_make_finalize_job" =>
      host.make_finalize_job(i64(args[0]), i64(args[1]))
    "sqlite3_make_discard_job" =>
      match self.sqlite_job(i64(args[0])).discard() {
        Some(job) => job
        None => return [I64(self.runtime.handles.null_handle)]
      }
    "sqlite3_take_job_handle" =>
      return [I64(host.take_job_handle(self.sqlite_job(i64(args[0]))))]
    "sqlite3_job_result" => {
      let (memory, address) = sqlite_range(caller, i32(args[1]), 24L)
      let result = self.sqlite_job(i64(args[0])).outcome()
      memory.store_i32_at(address, result.code)
      memory.store_i32_at(address + 4L, result.extended)
      memory.store_i32_at(address + 8L, result.tail)
      memory.store_i32_at(
        address + 12L,
        if result.changes is Some(_) {
          1
        } else {
          0
        },
      )
      memory.store_i64_at(address + 16L, result.changes.unwrap_or(0L))
      return []
    }
    "sqlite3_job_message16_length" =>
      return [I32(self.sqlite_job(i64(args[0])).outcome().message.length())]
    "sqlite3_job_message16" =>
      return [
        I32(
          sqlite_copy_string(
            caller,
            i32(args[1]),
            i32(args[2]),
            self.sqlite_job(i64(args[0])).outcome().message,
          ),
        ),
      ]
    _ => raise @vm.UnknownImport("moonbitlang/sqlite", name)
  }
  [
    I64(
      self.runtime.async_host.new_job(
        () => job.prepare(),
        cleanup=() => job.close(),
        sqlite=job,
      ),
    ),
  ]
}
