///|
fn Context::filesystem(
  self : Context,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let filesystem = self.runtime.filesystem
  match name {
    "begin_create_string" => [self.put(Builder(StringBuilder()))]
    "string_append_char" => {
      guard self.get(args[0]) is Builder(builder) else {
        raise @vm.TypeMismatch
      }
      builder.write_char((i32(args[1]) & 0xFFFF).unsafe_to_char())
      []
    }
    "finish_create_string" => {
      guard self.get(args[0]) is Builder(builder) else {
        raise @vm.TypeMismatch
      }
      [self.put(Text(builder.to_string()))]
    }
    "begin_read_string" => [self.put(TextReader(self.text(args[0]), Ref(0)))]
    "string_read_char" => {
      guard self.get(args[0]) is TextReader(text, index) else {
        raise @vm.TypeMismatch
      }
      let value = if index.val < text.length() {
        let value = text.code_unit_at(index.val).to_int()
        index.val += 1
        value
      } else {
        -1
      }
      [I32(value)]
    }
    "begin_create_byte_array" => [self.put(ByteBuilder([]))]
    "byte_array_append_byte" => {
      guard self.get(args[0]) is ByteBuilder(bytes) else {
        raise @vm.TypeMismatch
      }
      bytes.push(i32(args[1]).to_byte())
      []
    }
    "finish_create_byte_array" => {
      guard self.get(args[0]) is ByteBuilder(bytes) else {
        raise @vm.TypeMismatch
      }
      [self.put(Bytes(FixedArray::makei(bytes.length(), i => bytes[i])))]
    }
    "begin_read_byte_array" =>
      [self.put(ByteReader(self.bytes(args[0]), Ref(0)))]
    "byte_array_read_byte" => {
      guard self.get(args[0]) is ByteReader(bytes, index) else {
        raise @vm.TypeMismatch
      }
      let value = match bytes.get(index.val) {
        Some(byte) => {
          index.val += 1
          byte.to_int()
        }
        None => -1
      }
      [I32(value)]
    }
    "begin_read_string_array" => {
      guard self.get(args[0]) is Strings(strings) else {
        raise @vm.TypeMismatch
      }
      [self.put(StringReader(strings, Ref(0)))]
    }
    "string_array_read_string" => {
      guard self.get(args[0]) is StringReader(strings, index) else {
        raise @vm.TypeMismatch
      }
      let value = match strings.get(index.val) {
        Some(text) => {
          index.val += 1
          self.put(Text(text))
        }
        None => self.put(Text("ffi_end_of_/string_array"))
      }
      [value]
    }
    "finish_read_string"
    | "finish_read_byte_array"
    | "finish_read_string_array" => []
    "array_len" => {
      guard self.get(args[0]) is Strings(strings) else {
        raise @vm.TypeMismatch
      }
      [I32(strings.length())]
    }
    "array_get" => {
      guard self.get(args[0]) is Strings(strings) &&
        strings.get(i32(args[1])) is Some(text) else {
        raise @vm.TypeMismatch
      }
      [self.put(Text(text))]
    }
    "jsvalue_is_string" =>
      [
        I32(
          if args[0] is ExternRef(index) &&
            self.values.get(index) is Some(Text(_)) {
            1
          } else {
            0
          },
        ),
      ]
    "args_get" => [self.put(Strings(self.runtime.args))]
    "env_get_var" | "get_env_var" =>
      [
        self.put(
          Text(
            @environment.environment_entry(self.runtime.env, self.text(args[0]))
            .map(entry => entry.1)
            .unwrap_or(""),
          ),
        ),
      ]
    "get_env_var_exists" =>
      [
        I32(
          if @environment.environment_entry(
              self.runtime.env,
              self.text(args[0]),
            )
            is Some(_) {
            1
          } else {
            0
          },
        ),
      ]
    "set_env_var" => {
      @environment.set_environment_entry(
        self.runtime.env,
        self.text(args[0]),
        self.text(args[1]),
      )
      self.sync_wasi_environment()
      []
    }
    "unset_env_var" => {
      if @environment.environment_entry(self.runtime.env, self.text(args[0]))
        is Some((key, _)) {
        self.runtime.env.remove(key)
      }
      self.sync_wasi_environment()
      []
    }
    "get_env_vars" => {
      let values = []
      for key, value in self.runtime.env {
        values.push(key)
        values.push(value)
      }
      [self.put(Strings(values))]
    }
    "current_dir" => [self.put(Text(self.runtime.cwd))]
    "get_file_content" =>
      [self.put(Bytes(self.filesystem_results.file_content))]
    "get_dir_files" =>
      [self.put(Strings(self.filesystem_results.directory_entries))]
    "get_error_message" =>
      [self.put(Text(self.filesystem_results.error_message))]
    _ => {
      let requested = self.text(args[0])
      let path = filesystem.resolve(requested)
      let contents = if name == "write_string_to_file" {
        @utf8.encode(self.text(args[1]))
      } else if name == "write_bytes_to_file" ||
        name == "write_bytes_to_file_new" {
        Bytes::from_array(self.bytes(args[1]))
      } else {
        b""
      }
      self.suspend(async fn() {
        let result : Array[@wasm.Value] = try {
          match name {
            "read_file_to_string" =>
              [self.put(Text(filesystem.read_file_to_string(path)))]
            "read_file_to_bytes_new" => {
              self.filesystem_results.file_content = filesystem.read_file_to_bytes(
                path,
              )
              [I32(0)]
            }
            "write_string_to_file"
            | "write_bytes_to_file"
            | "write_bytes_to_file_new" => {
              filesystem.write_file(path, contents)
              if name == "write_bytes_to_file_new" {
                [I32(0)]
              } else {
                []
              }
            }
            "create_dir" | "create_dir_new" => {
              filesystem.create_dir(path)
              if name == "create_dir_new" {
                [I32(0)]
              } else {
                []
              }
            }
            "remove_file" | "remove_file_new" => {
              filesystem.remove_file(path)
              if name == "remove_file_new" {
                [I32(0)]
              } else {
                []
              }
            }
            "remove_dir" | "remove_dir_new" => {
              filesystem.remove_dir(path)
              if name == "remove_dir_new" {
                [I32(0)]
              } else {
                []
              }
            }
            "read_dir" | "read_dir_new" => {
              let entries = filesystem.read_dir(path)
              if name == "read_dir_new" {
                self.filesystem_results.directory_entries = entries
                [I32(0)]
              } else {
                [self.put(Strings(entries))]
              }
            }
            "is_file" | "is_file_new" =>
              [I32(if filesystem.is_file(path) { 1 } else { 0 })]
            "is_dir" | "is_dir_new" =>
              [I32(if filesystem.is_dir(path) { 1 } else { 0 })]
            "path_exists" =>
              [I32(if filesystem.path_exists(path) { 1 } else { 0 })]
            _ => raise @vm.UnknownImport("__moonbit_fs_unstable", name)
          }
        } catch {
          @os_error.OSError(_, ..) as error => {
            let message = "\{error}"
            let context = match name {
              "read_file_to_string" | "read_file_to_bytes_new" =>
                "Failed to read file"
              "write_string_to_file"
              | "write_bytes_to_file"
              | "write_bytes_to_file_new" => "Failed to write file"
              "create_dir" | "create_dir_new" => "Failed to create directory"
              "read_dir" | "read_dir_new" => "Failed to read directory"
              "remove_file" | "remove_file_new" => "Failed to remove file"
              "remove_dir" | "remove_dir_new" => "Failed to remove directory"
              _ => ""
            }
            let diagnostic = if context.is_empty() {
              "\{message}: \{requested}"
            } else {
              "\{context} \{requested}: \{message}"
            }
            if name.has_suffix("_new") {
              self.filesystem_results.error_message = diagnostic
              [I32(-1)]
            } else if name == "is_file" || name == "is_dir" {
              [I32(0)]
            } else {
              raise @vm.AsyncHostError(diagnostic)
            }
          }
          @utf8.Malformed(_) =>
            raise @vm.AsyncHostError(
              "Failed to read file \{requested}: stream did not contain valid UTF-8",
            )
          error => raise error
        }
        result
      })
    }
  }
}

///|
fn Context::sync_wasi_environment(self : Context) -> Unit {
  if self.wasi_context is Some(context) {
    context.env.clear()
    for key, value in self.runtime.env {
      context.env.push("\{key}=\{value}")
    }
  }
}
