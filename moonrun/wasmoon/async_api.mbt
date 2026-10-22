///|
priv enum AsyncImport {
  Worker
  EventBus
  Io
  TemporaryPath
  Buffer
  Legacy
  Watcher
  Process
  IoResult
  File
  Directory
  Address
  Socket
  Dns
  SocketOption
  Tls
  Common
}

///|
fn async_import_spec(name : String) -> (AsyncImport, @wasm.FuncType)? {
  let (params, results) : (
    ReadOnlyArray[@wasm.ValueType],
    ReadOnlyArray[@wasm.ValueType],
  ) = match name {
    "fs/get_tmp_path_len" => ([], [I32])
    "fs/get_tmp_path" => ([I32, I32], [I32])
    "fs/get_tmp_path_buffer" => ([], [I64])
    "thread_pool/init_thread_pool" => ([I64], [I64])
    "thread_pool/destroy_thread_pool" => ([], [])
    "thread_pool/make_sleep_job" => ([I32], [I64])
    "thread_pool/spawn_worker" => ([I32, I64], [I64])
    "thread_pool/wake_worker" => ([I64, I32, I64], [])
    "thread_pool/free_worker"
    | "thread_pool/worker_enter_idle"
    | "thread_pool/free_job" => ([I64], [])
    "thread_pool/cancel_worker"
    | "thread_pool/cancel_worker_with_retry"
    | "thread_pool/job_get_ret"
    | "thread_pool/job_get_err" => ([I64], [I32])
    "thread_pool/fetch_completion/unix" => ([I64, I32, I32], [I32])
    "thread_pool/errno_is_cancelled" => ([I32], [I32])
    "event_bus/create" => ([], [I64])
    "event_bus/destroy" => ([I64], [])
    "event_bus/wait" => ([I64, I32], [I32])
    "event_bus/try_register" => ([I64, I64, I32], [I32])
    "event_bus/get_event" => ([I64, I32], [I64])
    "event_bus/event_fd" => ([I64], [I64])
    "event_bus/event_events/unix" => ([I64], [I32])
    "event_bus/event_bytes_transferred/windows" => ([I64], [I32])
    "event_bus/event_io_result/windows" => ([I64], [I64])
    "event_bus/event_pid" => ([I64], [I32])
    "fd_util/pipe" => ([I32, I32, I32, I32], [I32])
    "fd_util/close_fd" => ([I64], [I32])
    "fd_util/set_cloexec" => ([I64], [I32])
    "fd_util/invalid_fd" => ([], [I64])
    "io/read/unix" | "io/write/unix" => ([I64, I32, I32, I32], [I32])
    "time/get_ms_since_epoch" => ([], [I64])
    "os_error/get_errno" => ([], [I32])
    "c_buffer/new" => ([I32], [I64])
    "c_buffer/free" => ([I64], [])
    "c_buffer/is_null" | "c_buffer/length" | "c_buffer/strlen" => ([I64], [I32])
    "c_buffer/c_buffer_get" => ([I64, I32], [I32])
    "c_buffer/blit_to_c" | "c_buffer/blit_from_c" =>
      ([I64, I32, I32, I32, I32], [])
    _ => {
      let families : Array[(AsyncImport, (String) -> @wasm.FuncType?)] = [
        (Legacy, legacy_async_signature),
        (Watcher, watcher_signature),
        (Process, process_signature),
        (IoResult, io_result_signature),
        (File, file_job_signature),
        (Directory, directory_signature),
        (Address, socket_address_signature),
        (Socket, socket_signature),
        (Dns, dns_signature),
        (SocketOption, socket_option_signature),
        (Tls, tls_signature),
        (Common, common_async_signature),
      ]
      for (family, lookup) in families {
        if lookup(name) is Some(signature) {
          return Some((family, signature))
        }
      }
      return None
    }
  }
  let family = if name.has_prefix("thread_pool/") {
    Worker
  } else if name.has_prefix("event_bus/") {
    EventBus
  } else if name.has_prefix("fd_util/") || name.has_prefix("io/") {
    Io
  } else if name.has_prefix("fs/") {
    TemporaryPath
  } else {
    Buffer
  }
  Some((family, { params, results, }))
}

///|
fn Context::async_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
  family : AsyncImport,
) -> Array[@wasm.Value] raise {
  match family {
    Worker => self.worker_import(caller, name, args)
    EventBus => self.event_bus_import(name, args)
    Io => self.pipe_import(caller, name, args)
    TemporaryPath => self.temporary_path_import(caller, name, args)
    Buffer => self.buffer_import(caller, name, args)
    Legacy => self.legacy_async_import(caller, name, args)
    Watcher => self.watcher_import(caller, name, args)
    Process => self.process_import(caller, name, args)
    IoResult => self.io_result_import(caller, name, args)
    File => self.file_job_import(caller, name, args)
    Directory => self.directory_import(name, args)
    Address => self.socket_address_import(caller, name, args)
    Socket => self.windows_socket_import(caller, name, args)
    Dns => self.dns_import(caller, name, args)
    SocketOption => self.socket_option_import(caller, name, args)
    Tls => self.tls_import(caller, name, args)
    Common => self.common_async_import(caller, name, args)
  }
}
