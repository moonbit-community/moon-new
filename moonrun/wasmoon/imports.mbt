///|
fn Context::register(
  self : Context,
  linker : @vm.Linker,
  code : @wasm.Module,
) -> @vm.Imports raise {
  let store = linker.get_store()
  let host_exception_tag = store.alloc_tag({ params: [ExternRef], results: [], })
  self.host_exception_tag = Some(host_exception_tag)
  let imports = @vm.Imports(store)
  let exception : @wasm.Module = {
    ..@wasm.Module::empty(),
    types: [@wasm.SubType::func([], [])],
    type_rec_groups: [0],
    tags: [{ type_idx: 0, }],
    funcs: [0],
    codes: [{ locals: [], body: [Throw(0)], }],
    exports: [{ name: "throw", desc: Func(0), }, { name: "tag", desc: Tag(0), }],
  }
  linker.register(
    "exception",
    @executor.instantiate_module_with_imports(
      linker.get_store(),
      exception,
      @vm.Imports(linker.get_store()),
    ),
  )
  if code.imports.any(entry => entry.mod_name == "wasi_snapshot_preview1") {
    let builder = @wasi.WasiContextBuilder()
      .args(self.runtime.args)
      .inherit_stdio()
      .preopen_dir(self.runtime.cwd, ".")
    for key, value in self.runtime.env {
      builder.env(key, value) |> ignore
    }
    if self.runtime.stdio.stdin is Some(read) {
      builder.stdin(read) |> ignore
    }
    if self.runtime.stdio.stdout is Some(write) {
      builder.stdout(write) |> ignore
    }
    if self.runtime.stdio.stderr is Some(write) {
      builder.stderr(write) |> ignore
    }
    let context = builder.build()
    self.wasi_context = Some(context)
    @wasi.register_wasi(linker, context)
  }
  let registered : Set[(String, String)] = Set([])
  for entry in code.imports {
    let module_name = entry.mod_name
    let name = entry.name
    if module_name == "exception" ||
      module_name == "wasi_snapshot_preview1" ||
      registered.contains((module_name, name)) {
      continue
    }
    registered.add((module_name, name))
    match (module_name, name, entry.desc) {
      ("_", literal, Global(_)) =>
        linker.add_global(
          module_name,
          name,
          @vm.GlobalInstance(
            { value_type: RefExtern, mutable: false, },
            self.put(Text(literal)),
          ),
        )
      ("ffi-bytes", "memory", Memory(_)) => {
        let memory = @vm.Memory::Memory(1, None)
        self.ffi_memory = Some(memory)
        linker.add_memory(module_name, name, memory)
      }
      (_, _, Func(type_index)) => {
        guard code.types[type_index].composite is Func(actual) else {
          raise @vm.TypeMismatch
        }
        let compatible = if module_name == "wasm:js-string" {
          js_string_signature(name, code, actual)
        } else if module_name == "ffi-bytes" {
          ffi_bytes_signature(name, actual)
        } else if import_signature(module_name, name) is Some(expected) {
          let params : ReadOnlyArray[@wasm.ValueType] = actual.params.map(ty => {
            if ty is RefExtern {
              ExternRef
            } else {
              ty
            }
          })
          params == expected.params && actual.results == expected.results
        } else {
          raise @vm.UnknownImport(module_name, name)
        }
        guard compatible else {
          raise @vm.LinkErrorDetail(
            "incompatible entry type for \{module_name}.\{name}",
          )
        }
        // Resolve the async family once; guest calls do not rebuild signatures.
        let family = if module_name == "moonbitlang/async" {
          async_import_spec(name).map(spec => spec.0)
        } else {
          None
        }
        let address = store.alloc_throwing_host_func_with_caller(
          (caller, args) => {
            // Polling, cancellation and termination stay outside guest catches.
            self.progress()
            try {
              match family {
                Some(family) => self.async_import(caller, name, args, family)
                None => {
                  let values = self.dispatch_impl(
                    caller, module_name, name, args,
                  )
                  if actual.results.is_empty() {
                    []
                  } else {
                    values
                  }
                }
              }
            } catch {
              error => {
                let error = import_error(error)
                // JS string builtins trap; ABI validation and operation errors
                // throw like the Rust runner's host bindings. Engine resource
                // failures and process exit are not converted to exceptions.
                guard module_name != "wasm:js-string" &&
                  error
                  is (@vm.TypeMismatch
                  | @vm.OutOfBoundsMemoryAccess
                  | @vm.OutOfBoundsArrayAccess
                  | @vm.LinkErrorDetail(_)
                  | @vm.AsyncHostError(_)) else {
                  raise error
                }
                let payload = store.root_raw_value(self.put(HostError(error)))
                defer payload.close()
                let exception = store.guest_exception(host_exception_tag, [
                  payload,
                ])
                defer exception.close()
                exception.throw_into_guest()
              }
            }
          },
          func_type=actual,
        )
        imports.add_func(module_name, name, address)
      }
      _ => raise @vm.UnknownImport(module_name, name)
    }
  }
  let registered_imports = linker.build_imports()
  for entry in code.imports {
    let value = if entry.mod_name == "wasi_snapshot_preview1" &&
      (entry.name == "fd_read" || entry.name == "fd_write") &&
      self.wasi_context is Some(context) {
      @vm.ExternVal::Func(
        linker
        .get_store()
        .alloc_host_func_with_caller(
          (caller, args) => {
            if entry.name == "fd_read" {
              self.wasi_read(context, caller, args) catch {
                error => raise import_error(error)
              }
            } else {
              self.wasi_write(context, caller, args) catch {
                error => raise import_error(error)
              }
            }
          },
          func_type={ params: [I32, I32, I32, I32], results: [I32], },
        ),
      )
    } else {
      imports
      .resolve(entry.mod_name, entry.name)
      .unwrap_or_else(() => {
        guard registered_imports.resolve(entry.mod_name, entry.name)
          is Some(value) else {
          raise @vm.UnknownImport(entry.mod_name, entry.name)
        }
        value
      })
    }
    match value {
      Func(address) => imports.add_func(entry.mod_name, entry.name, address)
      Memory(address) => imports.add_memory(entry.mod_name, entry.name, address)
      Global(address) => imports.add_global(entry.mod_name, entry.name, address)
      Table(address) => imports.add_table(entry.mod_name, entry.name, address)
      Tag(address) => imports.add_tag(entry.mod_name, entry.name, address)
    }
  }
  imports
}

///|
fn import_signature(module_name : String, name : String) -> @wasm.FuncType? {
  if module_name == "moonbitlang/async" {
    return async_import_spec(name).map(spec => spec.1)
  }
  if module_name == "moonbitlang/sqlite" {
    return sqlite_signature(name)
  }
  let (params, results) : (
    ReadOnlyArray[@wasm.ValueType],
    ReadOnlyArray[@wasm.ValueType],
  ) = match (module_name, name) {
    ("moonbitlang/core", "env/current_exe" | "env/current_exe_dir") =>
      ([], [I64])
    ("moonbit:ffi/memory-sanitizer", name) =>
      match name {
        "register-object-alloc" => ([I32, I32], [])
        "register-object-free" => ([I32], [])
        "object-is-valid" => ([I32], [I32])
        _ => return None
      }
    ("ffi-bytes", name) =>
      match name {
        "new" => ([I32], [ExternRef])
        "from_memory" => ([I32, I32], [ExternRef])
        "get" => ([ExternRef, I32], [I32])
        "set" => ([ExternRef, I32, I32], [])
        "length" => ([ExternRef], [I32])
        "equals" => ([ExternRef, ExternRef], [I32])
        "copy" => ([ExternRef, I32, ExternRef, I32, I32], [])
        "fill" => ([ExternRef, I32, I32, I32], [])
        "asString" => ([ExternRef, I32, I32], [ExternRef])
        _ => return None
      }
    ("spectest", "print_char") | ("moonbit", "string_to_js_string") =>
      ([I32], [])
    ("console", "log") => ([ExternRef], [])
    ("__moonbit_sys_unstable", "exit") => ([I32], [])
    ("__moonbit_sys_unstable", "is_windows") => ([], [I32])
    ("__moonbit_io_unstable", "write_char") => ([I32, I32], [])
    ("__moonbit_io_unstable", "flush") => ([I32], [])
    ("__moonbit_io_unstable", "read_char") | ("spectest", "read_char") =>
      ([], [I32])
    ("__moonbit_io_unstable", "read_bytes_from_stdin") => ([], [ExternRef])
    ("__moonbit_time_unstable", "now") => ([], [I64])
    ("__moonbit_time_unstable", "instant_now") => ([], [ExternRef])
    ("__moonbit_time_unstable", "instant_elapsed_as_secs_f64") =>
      ([ExternRef], [F64])
    ("__moonbit_fs_unstable", name) =>
      match name {
        "begin_create_string"
        | "begin_create_byte_array"
        | "args_get"
        | "get_env_vars"
        | "current_dir"
        | "get_file_content"
        | "get_dir_files"
        | "get_error_message" => ([], [ExternRef])
        "string_append_char" | "byte_array_append_byte" =>
          ([ExternRef, I32], [])
        "finish_create_string"
        | "finish_create_byte_array"
        | "begin_read_string"
        | "begin_read_byte_array"
        | "begin_read_string_array"
        | "string_array_read_string"
        | "env_get_var"
        | "get_env_var"
        | "read_file_to_string"
        | "read_dir" => ([ExternRef], [ExternRef])
        "finish_read_string"
        | "finish_read_byte_array"
        | "finish_read_string_array"
        | "unset_env_var"
        | "create_dir"
        | "remove_file"
        | "remove_dir" => ([ExternRef], [])
        "string_read_char"
        | "byte_array_read_byte"
        | "array_len"
        | "jsvalue_is_string"
        | "get_env_var_exists"
        | "is_file"
        | "is_dir"
        | "path_exists"
        | "read_file_to_bytes_new"
        | "create_dir_new"
        | "read_dir_new"
        | "is_file_new"
        | "is_dir_new"
        | "remove_file_new"
        | "remove_dir_new" => ([ExternRef], [I32])
        "array_get" => ([ExternRef, I32], [ExternRef])
        "set_env_var" | "write_string_to_file" | "write_bytes_to_file" =>
          ([ExternRef, ExternRef], [])
        "write_bytes_to_file_new" => ([ExternRef, ExternRef], [I32])
        _ => return None
      }
    _ => return None
  }
  Some({ params, results, })
}

///|
fn Context::dispatch_impl(
  self : Context,
  caller : @vm.Caller,
  module_name : String,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  match (module_name, name) {
    ("moonbitlang/sqlite", _) =>
      self.sqlite_import(caller, name, args) catch {
        @sqlite.InvalidHandle =>
          raise @vm.LinkErrorDetail(
            "moonbitlang/sqlite.\{name} failed: InvalidHandle",
          )
        @sqlite.Fault | @vm.TypeMismatch | @vm.OutOfBoundsMemoryAccess =>
          raise @vm.LinkErrorDetail("moonbitlang/sqlite.\{name} failed: Fault")
        @sqlite.Overflow =>
          raise @vm.LinkErrorDetail(
            "moonbitlang/sqlite.\{name} failed: Overflow",
          )
        error => raise error
      }
    ("moonbitlang/core", "env/current_exe" | "env/current_exe_dir") => {
      guard self.runtime.executable is Some(path) else {
        self.runtime.async_host.async_errno = if @sys.platform is Windows {
          87
        } else {
          22
        }
        return [I64(self.runtime.handles.null_handle)]
      }
      let path = if name == "env/current_exe_dir" {
        @path.Path(path).dirname().to_string()
      } else {
        path
      }
      let bytes = if @sys.platform is Windows {
        @utf16.encode(path + "\u0000", endianness=Little, bom=false)
      } else {
        @utf8.encode(path + "\u0000")
      }
      let handle = self.runtime.handles.allocate()
      self.runtime.async_host.buffers[handle] = bytes.to_fixedarray()
      [I64(handle)]
    }
    ("moonbit:ffi/memory-sanitizer", _) => self.memory_sanitizer(name, args)
    ("spectest", "print_char") | ("moonbit", "string_to_js_string") => {
      let unit = i32(args[0])
      self.runtime.stdio.print_unit(unit)
      []
    }
    ("console", "log") => {
      let bytes = @utf8.encode(self.text(args[0]) + "\n")
      self.runtime.stdio.output(1, bytes)
      []
    }
    ("__moonbit_sys_unstable", "exit") => {
      let code = i32(args[0])
      self.exit_code = Some(code)
      raise @vm.HostExit(code)
    }
    ("__moonbit_sys_unstable", "is_windows") =>
      [I32(if @path.sep == '\\' { 1 } else { 0 })]
    ("__moonbit_io_unstable", "write_char") => {
      let code = i32(args[1])
      guard code >= 0 && code <= 0x10FFFF && !(code >= 0xD800 && code <= 0xDFFF) else {
        raise @vm.TypeMismatch
      }
      let fd = i32(args[0])
      let bytes = @utf8.encode(code.unsafe_to_char().to_string())
      if fd == 1 || fd == 2 {
        self.runtime.stdio.output(fd, bytes)
      }
      []
    }
    ("__moonbit_io_unstable", "flush") => []
    ("__moonbit_io_unstable", "read_char") | ("spectest", "read_char") =>
      [
        I32(
          self.runtime.stdio.read_char() catch {
            @sys.OSError(_, ..) => -1
            error => raise error
          },
        ),
      ]
    ("__moonbit_io_unstable", "read_bytes_from_stdin") =>
      [self.put(Bytes(self.runtime.stdio.read_all().to_fixedarray()))]
    ("__moonbit_time_unstable", "now") =>
      [I64(@env.now().reinterpret_as_int64())]
    ("__moonbit_time_unstable", "instant_now") =>
      [self.put(Instant(@wasi.native_clock_gettime_monotonic()))]
    ("__moonbit_time_unstable", "instant_elapsed_as_secs_f64") => {
      guard self.get(args[0]) is Instant(start) else { raise @vm.TypeMismatch }
      [
        F64(
          (@wasi.native_clock_gettime_monotonic() - start).to_double() /
          1000000000.0,
        ),
      ]
    }
    ("ffi-bytes", _) => self.ffi_bytes(name, args)
    ("wasm:js-string", _) => self.js_string(caller, name, args)
    ("__moonbit_fs_unstable", _) => self.filesystem(name, args)
    _ => raise @vm.UnknownImport(module_name, name)
  }
}

///|
fn import_error(error : Error) -> @vm.RuntimeError {
  match error {
    @sys.Invalid => @vm.TypeMismatch
    @sys.Bounds => @vm.OutOfBoundsMemoryAccess
    @sys.Operation(message) => @vm.LinkErrorDetail(message)
    error =>
      @vm.RuntimeError::from_error(error).unwrap_or_else(() => {
        @vm.AsyncHostError("\{error}")
      })
  }
}
