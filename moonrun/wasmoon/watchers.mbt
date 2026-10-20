///|
fn watcher_signature(name : String) -> @wasm.FuncType? {
  let (params, results) : (
    ReadOnlyArray[@wasm.ValueType],
    ReadOnlyArray[@wasm.ValueType],
  ) = match name {
    "fs/watcher/windows/buffer/new" => ([], [I64])
    "fs/watcher/windows/buffer/free" => ([I64], [])
    "fs/watcher/windows/event_get_size"
    | "fs/watcher/windows/event_is_modify"
    | "fs/watcher/windows/event_path_len" => ([I64, I32], [I32])
    "fs/watcher/windows/event_path_copy" => ([I64, I32, I32, I32], [])
    "fs/watcher/windows/event_has_file_ids" => ([I64], [I32])
    "fs/watcher/windows/event_dirty_file_id" => ([I64, I32], [I64])
    "fs/inotify/create" | "fs/kqueue_watcher/create" => ([], [I64])
    "fs/inotify/event_buffer_size" | "fs/kqueue_watcher/buffer_size" =>
      ([], [I32])
    "fs/inotify/remove_file" => ([I64, I64], [I32])
    "fs/kqueue_watcher/add_file" => ([I64, I64, I32], [I32])
    "fs/inotify/fetch_event" | "fs/kqueue_watcher/fetch_event" =>
      ([I64, I64, I32], [I32])
    "fs/inotify/event_get_wd" | "fs/kqueue_watcher/event_get_fd" =>
      ([I64, I32], [I64])
    "fs/inotify/event_get_size"
    | "fs/inotify/event_has_relevant_event"
    | "fs/inotify/event_has_overflow"
    | "fs/inotify/event_has_ignore"
    | "fs/kqueue_watcher/event_has_modify" => ([I64, I32], [I32])
    "thread_pool/make_inotify_add_watch_job" => ([I64, I32, I32, I32], [I64])
    _ => return None
  }
  Some({ params, results, })
}

///|
fn Context::watcher_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.async_host
  if name.has_prefix("fs/watcher/windows/") {
    guard @async.platform is Windows else {
      raise @vm.UnknownImport("moonbitlang/async", name)
    }
    if name == "fs/watcher/windows/buffer/new" {
      let handle = self.runtime.handles.allocate()
      host.buffers[handle] = FixedArray::make(65536, b'\x00')
      return [I64(handle)]
    }
    guard host.buffers.get(i64(args[0])) is Some(buffer) else {
      raise @vm.TypeMismatch
    }
    if name == "fs/watcher/windows/buffer/free" {
      host.buffers.remove(i64(args[0]))
      return []
    }
    // ReadDirectoryChangesW provides names; the guest's established fallback
    // opens those names to determine identities when extended records are absent.
    if name == "fs/watcher/windows/event_has_file_ids" {
      return [I32(0)]
    }
    let offset = i32(args[1])
    @sys.check_range(offset, 12, buffer.length())
    let next = @sys.buffer_word(buffer, offset, 4)
    let bytes = @sys.buffer_word(buffer, offset + 8, 4)
    guard bytes % 2L == 0L &&
      offset.to_int64() + 12L + bytes <= buffer.length().to_int64() &&
      (
        next == 0L ||
        (
          next >= 12L + bytes &&
          offset.to_int64() + next <= buffer.length().to_int64()
        )
      ) else {
      raise @vm.OutOfBoundsMemoryAccess
    }
    return match name {
      "fs/watcher/windows/event_get_size" => [I32(next.to_int())]
      "fs/watcher/windows/event_is_modify" =>
        [I32(if @sys.buffer_word(buffer, offset + 4, 4) == 3L { 1 } else { 0 })]
      "fs/watcher/windows/event_path_len" => [I32((bytes / 2L).to_int())]
      "fs/watcher/windows/event_path_copy" => {
        guard i32(args[3]).to_int64() * 2L == bytes else {
          raise @vm.TypeMismatch
        }
        let pointer = i32(args[2]).reinterpret_as_uint().to_int64()
        guard pointer + bytes <= guest_memory(caller).byte_len() else {
          raise @vm.OutOfBoundsMemoryAccess
        }
        guest_memory(caller).init_data_at(
          pointer,
          Bytes::from_array(buffer[offset + 12:offset + 12 + bytes.to_int()]),
        )
        []
      }
      _ => raise @vm.TypeMismatch
    }
  }
  guard (name.contains("inotify") && @async.platform is Linux) ||
    (name.contains("kqueue_watcher") && @async.platform is MacOS) else {
    raise @vm.UnknownImport("moonbitlang/async", name)
  }
  if name.has_suffix("/create") {
    let fd = @sys.create_watcher()
    if fd == @sys.invalid_native_fd() {
      host.async_errno = @os_error.get_errno()
      return [I64(self.runtime.handles.invalid_fd)]
    }
    let handle = self.runtime.handles.allocate()
    host.fds[handle] = @resource.Resource(
      @resource.Watcher({ fd, files: Map([]), }),
    )
    return [I64(handle)]
  }
  if name.has_suffix("buffer_size") {
    return [I32(@sys.watcher_buffer_size())]
  }
  if name.has_prefix("fs/inotify/event_") ||
    name.has_prefix("fs/kqueue_watcher/event_") {
    guard host.buffers.get(i64(args[0])) is Some(buffer) else {
      raise @vm.TypeMismatch
    }
    let offset = i32(args[1])
    if @async.platform is MacOS {
      guard offset >= 0 && offset <= buffer.length() / 32 - 1 else {
        raise @vm.OutOfBoundsMemoryAccess
      }
      let offset = offset * 32
      if name == "fs/kqueue_watcher/event_get_fd" {
        return [I64(@sys.buffer_word(buffer, offset, 8))]
      }
      return [
        I32(
          if (@sys.buffer_word(buffer, offset + 12, 4).to_int() & 6) != 0 {
            1
          } else {
            0
          },
        ),
      ]
    }
    let size = 16L + @sys.buffer_word(buffer, offset + 12, 4)
    guard size >= 16L &&
      offset >= 0 &&
      offset.to_int64() + size <= buffer.length().to_int64() else {
      raise @vm.OutOfBoundsMemoryAccess
    }
    let flags = @sys.buffer_word(buffer, offset + 4, 4).to_int()
    if name == "fs/inotify/event_get_wd" {
      return [I64(@sys.buffer_word(buffer, offset, 4))]
    }
    [
      I32(
        match name {
          "fs/inotify/event_get_size" => size.to_int()
          "fs/inotify/event_has_overflow" =>
            if (flags & 0x4000) != 0 {
              1
            } else {
              0
            }
          "fs/inotify/event_has_ignore" =>
            if (flags & 0x8000) != 0 {
              1
            } else {
              0
            }
          _ => if (flags & 0x3C2) != 0 { 1 } else { 0 }
        },
      ),
    ]
  } else {
    guard host.fds.get(i64(args[0])) is Some(fd) &&
      fd.owner is @resource.Watcher(watcher) else {
      host.async_errno = @sys.bad_fd_errno
      return [I32(-1)]
    }
    match name {
      "fs/inotify/remove_file" => {
        let wd = i64(args[1])
        guard wd >= 0L && wd <= 0x7FFF_FFFFL else { raise @vm.TypeMismatch }
        self.socket_status(@sys.watcher_remove_file(watcher.fd, wd.to_int()))
      }
      "fs/kqueue_watcher/add_file" => {
        let handle = i64(args[1])
        guard host.fds.get(handle) is Some(file) else {
          host.async_errno = @sys.bad_fd_errno
          return [I32(-1)]
        }
        let result = @sys.watcher_add_file(
          watcher.fd,
          file.native(),
          i32(args[2]) != 0,
        )
        if result >= 0 {
          watcher.files[@sys.fd_word(file.native())] = handle
        }
        self.socket_status(result)
      }
      "thread_pool/make_inotify_add_watch_job" => {
        let path = self.runtime.filesystem.resolve(
          guest_string(caller, i32(args[1]), i32(args[2])),
        )
        let directory = i32(args[3]) != 0
        fd.retain()
        [
          I64(
            host.new_job(
              () => {
                self.runtime.filesystem.authorize_path(path)
                @native_jobs.run_native_job(
                  AddWatch,
                  path,
                  watcher.fd,
                  0,
                  0,
                  directory,
                )
              },
              cleanup=() => fd.release(),
            ),
          ),
        ]
      }
      _ => {
        guard host.buffers.get(i64(args[1])) is Some(buffer) else {
          raise @vm.TypeMismatch
        }
        let length = i32(args[2])
        @sys.check_range(0, length, buffer.length())
        let count = @sys.watcher_fetch(watcher.fd, buffer, length)
        if count >= 0 && @async.platform is MacOS {
          for index in 0..<count {
            let offset = index * 32
            let raw = @sys.buffer_word(buffer, offset, 8)
            let handle = watcher.files
              .get(raw)
              .unwrap_or(0L)
              .reinterpret_as_uint64()
            for byte in 0..<8 {
              buffer[offset + byte] = (handle >> (byte * 8)).to_byte()
            }
          }
        }
        self.socket_status(count)
      }
    }
  }
}
