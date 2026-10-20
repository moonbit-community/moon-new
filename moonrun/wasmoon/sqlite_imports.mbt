///|
fn sqlite_signature(name : String) -> @wasm.FuncType? {
  let (params, results) : (
    ReadOnlyArray[@wasm.ValueType],
    ReadOnlyArray[@wasm.ValueType],
  ) = match name {
    "sqlite3_null_handle" => ([], [I64])
    "sqlite3_make_open_job" => ([I32, I32, I32], [I64])
    "sqlite3_make_prepare_job" => ([I64, I32, I32, I32], [I64])
    "sqlite3_make_step_job" | "sqlite3_make_finalize_job" => ([I64, I64], [I64])
    "sqlite3_make_discard_job"
    | "sqlite3_take_job_handle"
    | "sqlite3_db_mutex"
    | "sqlite3_changes64" => ([I64], [I64])
    "sqlite3_job_result" => ([I64, I32], [])
    "sqlite3_job_message16_length"
    | "sqlite3_errmsg16_length"
    | "sqlite3_errcode"
    | "sqlite3_extended_errcode"
    | "sqlite3_close"
    | "sqlite3_step"
    | "sqlite3_reset"
    | "sqlite3_clear_bindings"
    | "sqlite3_finalize"
    | "sqlite3_column_count" => ([I64], [I32])
    "sqlite3_job_message16" | "sqlite3_errmsg16" => ([I64, I32, I32], [I32])
    "sqlite3_open_v2" => ([I32, I32, I32, I32, I64], [I32])
    "sqlite3_mutex_enter" | "sqlite3_mutex_leave" => ([I64], [])
    "sqlite3_prepare16_v2" => ([I64, I32, I32, I32, I32, I32], [I32])
    "sqlite3_bind_null"
    | "sqlite3_column_name16_length"
    | "sqlite3_column_type"
    | "sqlite3_column_text16_length"
    | "sqlite3_column_blob_length" => ([I64, I32], [I32])
    "sqlite3_bind_int64" => ([I64, I32, I64], [I32])
    "sqlite3_bind_double" => ([I64, I32, F64], [I32])
    "sqlite3_bind_text16" | "sqlite3_bind_blob" =>
      ([I64, I32, I32, I32, I32], [I32])
    "sqlite3_column_name16" | "sqlite3_column_text16" | "sqlite3_column_blob" =>
      ([I64, I32, I32, I32], [I32])
    "sqlite3_column_int64" => ([I64, I32], [I64])
    "sqlite3_column_double" => ([I64, I32], [F64])
    _ => return None
  }
  Some({ params, results, })
}

///|
fn Context::sqlite_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.sqlite
  match name {
    "sqlite3_null_handle" => [I64(self.runtime.handles.null_handle)]
    "sqlite3_open_v2" => {
      let (memory, output) = sqlite_range(caller, i32(args[2]), 8L)
      if self.ready is None {
        memory.store_i64_at(output, self.runtime.handles.null_handle)
      }
      let filename = sqlite_filename(caller, i32(args[0]), i32(args[1]))
      let flags = i32(args[3])
      let vfs = i64(args[4])
      self.suspend(() => {
        let (code, database) = host.open_v2(filename, flags, vfs)
        memory.store_i64_at(output, database)
        [I32(code)]
      })
    }
    "sqlite3_errmsg16_length" => [I32(host.errmsg(i64(args[0])).length())]
    "sqlite3_errmsg16" =>
      [
        I32(
          sqlite_copy_string(
            caller,
            i32(args[1]),
            i32(args[2]),
            host.errmsg(i64(args[0])),
          ),
        ),
      ]
    "sqlite3_errcode" | "sqlite3_extended_errcode" =>
      [I32(host.errcode(i64(args[0]), name == "sqlite3_extended_errcode"))]
    "sqlite3_changes64" => [I64(host.changes64(i64(args[0])))]
    "sqlite3_db_mutex" => [I64(host.db_mutex(i64(args[0])))]
    "sqlite3_mutex_enter" => {
      host.mutex_enter(i64(args[0]))
      []
    }
    "sqlite3_mutex_leave" => {
      host.mutex_leave(i64(args[0]))
      []
    }
    "sqlite3_close" => [I32(host.close_database(i64(args[0])))]
    "sqlite3_prepare16_v2" => {
      let (memory, output) = sqlite_range(caller, i32(args[4]), 8L)
      let tail = if i32(args[5]) == 0 {
        None
      } else {
        Some(sqlite_range(caller, i32(args[5]), 4L).1)
      }
      memory.store_i64_at(output, self.runtime.handles.null_handle)
      let offset = i32(args[2])
      if tail is Some(tail) {
        memory.store_i32_at(tail, offset)
      }
      let sql = sqlite_string(caller, i32(args[1]), offset, i32(args[3]))
      let (code, statement, consumed) = host.prepare(i64(args[0]), sql)
      memory.store_i64_at(output, statement)
      if tail is Some(tail) {
        memory.store_i32_at(tail, offset + consumed)
      }
      [I32(code)]
    }
    "sqlite3_bind_null" => [I32(host.bind_null(i64(args[0]), i32(args[1])))]
    "sqlite3_bind_int64" =>
      [I32(host.bind_int64(i64(args[0]), i32(args[1]), i64(args[2])))]
    "sqlite3_bind_double" => {
      guard args[2] is F64(value) else { raise @vm.TypeMismatch }
      [I32(host.bind_double(i64(args[0]), i32(args[1]), value))]
    }
    "sqlite3_bind_text16" =>
      [
        I32(
          host.bind_text(
            i64(args[0]),
            i32(args[1]),
            sqlite_string(caller, i32(args[2]), i32(args[3]), i32(args[4])),
          ),
        ),
      ]
    "sqlite3_bind_blob" =>
      [
        I32(
          host.bind_blob(
            i64(args[0]),
            i32(args[1]),
            sqlite_bytes(caller, i32(args[2]), i32(args[3]), i32(args[4])),
          ),
        ),
      ]
    "sqlite3_step" => [I32(host.step(i64(args[0])))]
    "sqlite3_reset" => [I32(host.reset(i64(args[0])))]
    "sqlite3_clear_bindings" => [I32(host.clear_bindings(i64(args[0])))]
    "sqlite3_finalize" => [I32(host.finalize(i64(args[0])))]
    "sqlite3_column_count" => [I32(host.column_count(i64(args[0])))]
    "sqlite3_column_name16_length" | "sqlite3_column_name16" => {
      let value = host.column_name(i64(args[0]), i32(args[1]))
      [
        I32(
          match value {
            None => -1
            Some(value) =>
              if name == "sqlite3_column_name16_length" {
                value.length()
              } else {
                sqlite_copy_string(caller, i32(args[2]), i32(args[3]), value)
              }
          },
        ),
      ]
    }
    "sqlite3_column_type" => [I32(host.column_type(i64(args[0]), i32(args[1])))]
    "sqlite3_column_int64" =>
      [I64(host.column_int64(i64(args[0]), i32(args[1])))]
    "sqlite3_column_double" =>
      [F64(host.column_double(i64(args[0]), i32(args[1])))]
    "sqlite3_column_text16_length" | "sqlite3_column_text16" => {
      let text = host.column_text(i64(args[0]), i32(args[1]))
      [
        I32(
          if name == "sqlite3_column_text16_length" {
            text.length()
          } else {
            sqlite_copy_string(caller, i32(args[2]), i32(args[3]), text)
          },
        ),
      ]
    }
    "sqlite3_column_blob_length" | "sqlite3_column_blob" => {
      let bytes = host.column_blob(i64(args[0]), i32(args[1]))
      [
        I32(
          if name == "sqlite3_column_blob_length" {
            bytes.length()
          } else {
            sqlite_copy_bytes(caller, i32(args[2]), i32(args[3]), bytes)
          },
        ),
      ]
    }
    _ => self.sqlite_job_import(caller, name, args)
  }
}
