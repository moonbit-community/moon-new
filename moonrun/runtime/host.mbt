///|
priv enum HostValue {
  Text(String)
  Bytes(FixedArray[Byte])
  Strings(Array[String])
  Builder(StringBuilder)
  ByteBuilder(Array[Byte])
  TextReader(String, Ref[Int32])
  ByteReader(FixedArray[Byte], Ref[Int32])
  StringReader(Array[String], Ref[Int32])
  Instant(Int64)
}

///|
priv struct Host {
  args : Array[String]
  env : Map[String, String]
  cwd : String
  policy : Policy?
  resolved_connect : Array[SocketRule]
  stdin : (() -> Bytes)?
  stdout : ((Bytes) -> Unit)?
  stderr : ((Bytes) -> Unit)?
  values : Array[HostValue]
  buffers : Map[Int64, FixedArray[Byte]]
  buses : Map[Int64, GuestEventBus]
  fds : Map[Int64, GuestFd]
  stdio_handles : Map[Int32, Int64]
  jobs : Map[Int64, GuestJob]
  workers : Map[Int64, GuestWorker]
  io_results : Map[Int64, GuestIoResult]
  address_info : Map[Int64, GuestAddrInfo]
  accepting : Set[Int64]
  process_env : Map[Int64, GuestEnvironment]
  process_args : Map[Int64, Array[String?]]
  children : Map[Int32, GuestChild]
  owned_children : Array[GuestChild]
  process_handles : Map[Int64, GuestProcessHandle]
  group : @async.TaskGroup[RunOutcome]
  mut pool : GuestThreadPool?
  mut shutting_down : Bool
  signals : Set[Int32]
  signal_waiters : Map[Int64, GuestSignalWaiter]
  mut signal_enabled : Bool
  mut termination_signal : Int32?
  mut current_bus : Int64?
  mut async_errno : Int32
  mut next_handle : Int64
  mut pending : (async () -> Array[@wasm.Value])?
  mut ready : Array[@wasm.Value]?
  mut exit_code : Int32?
  mut input : Bytes
  mut input_offset : Int32
  mut wasi_context : @wasi.WasiContext?
  mut ffi_memory : @vm.Memory?
  mut high_surrogate : Int32?
  mut file_content : FixedArray[Byte]
  mut directory_entries : Array[String]
  mut error_message : String
}

///|
fn Host::Host(
  name : String,
  args : Array[String],
  env : Map[String, String],
  cwd : String,
  stdin : (() -> Bytes)?,
  stdout : ((Bytes) -> Unit)?,
  stderr : ((Bytes) -> Unit)?,
  group : @async.TaskGroup[RunOutcome],
  policy : Policy?,
) -> Host {
  {
    args: [name, ..args],
    env: copy_environment(env),
    cwd,
    policy,
    resolved_connect: [],
    stdin,
    stdout,
    stderr,
    values: [],
    buffers: Map([]),
    buses: Map([]),
    fds: Map([]),
    stdio_handles: Map([]),
    jobs: Map([]),
    workers: Map([]),
    io_results: Map([]),
    address_info: Map([]),
    accepting: Set([]),
    process_env: Map([]),
    process_args: Map([]),
    children: Map([]),
    owned_children: [],
    process_handles: Map([]),
    group,
    pool: None,
    shutting_down: false,
    signals: Set([]),
    signal_waiters: Map([]),
    signal_enabled: false,
    termination_signal: None,
    current_bus: None,
    async_errno: 0,
    next_handle: 1L,
    pending: None,
    ready: None,
    exit_code: None,
    input: b"",
    input_offset: 0,
    wasi_context: None,
    ffi_memory: None,
    high_surrogate: None,
    file_content: [],
    directory_entries: [],
    error_message: "",
  }
}

///|
fn Host::put(self : Host, value : HostValue) -> @wasm.Value {
  let index = self.values.length()
  self.values.push(value)
  ExternRef(index)
}

///|
fn Host::get(
  self : Host,
  value : @wasm.Value,
) -> HostValue raise @vm.RuntimeError {
  guard value is ExternRef(index) && self.values.get(index) is Some(value) else {
    raise @vm.TypeMismatch
  }
  value
}

///|
fn Host::text(
  self : Host,
  value : @wasm.Value,
) -> String raise @vm.RuntimeError {
  guard self.get(value) is Text(text) else { raise @vm.TypeMismatch }
  text
}

///|
fn Host::bytes(
  self : Host,
  value : @wasm.Value,
) -> FixedArray[Byte] raise @vm.RuntimeError {
  guard self.get(value) is Bytes(bytes) else { raise @vm.TypeMismatch }
  bytes
}

///|
fn i32(value : @wasm.Value) -> Int32 raise @vm.RuntimeError {
  guard value is I32(value) else { raise @vm.TypeMismatch }
  value
}

///|
let output_lock : @async.Mutex = @async.Mutex()

///|
async fn Host::output(self : Host, fd : Int32, bytes : Bytes) -> Unit {
  let callback = if fd == 2 { self.stderr } else { self.stdout }
  if callback is Some(write) {
    write(bytes)
  } else {
    output_lock.acquire()
    defer output_lock.release()
    if fd == 2 {
      @stdio.stderr.write(bytes)
    } else {
      @stdio.stdout.write(bytes)
    }
  }
}

///|
async fn Host::print_unit(self : Host, unit : Int32) -> Unit {
  // Preserve the Rust runner UTF-16 writer, including a pending high surrogate
  // across intervening scalar output.
  if unit >= 0xD800 && unit <= 0xDBFF {
    if self.high_surrogate is Some(_) {
      self.output(1, b"\xef\xbf\xbd")
    }
    self.high_surrogate = Some(unit)
    return
  }
  let codepoint = if unit >= 0xDC00 && unit <= 0xDFFF {
    let high = self.high_surrogate
    self.high_surrogate = None
    match high {
      Some(high) => 0x10000 + ((high - 0xD800) << 10) + unit - 0xDC00
      None => 0xFFFD
    }
  } else {
    unit
  }
  guard codepoint >= 0 && codepoint <= 0x10FFFF else { raise @vm.TypeMismatch }
  self.output(1, @utf8.encode(codepoint.unsafe_to_char().to_string()))
}

///|
fn Host::resolve(self : Host, path : String) -> String {
  resolve_from(self.cwd, path)
}

///|
fn resolve_from(directory : String, path : String) -> String {
  // Leave empty names and symlink/.. resolution to the native filesystem.
  match (@async.platform, path) {
    (_, "") => path
    (Windows, ['a'..<='z' | 'A'..<='Z', ':', ..])
    | (Windows, ['\\' | '/', '\\' | '/', ..])
    | (Linux | MacOS, ['/', ..]) => path
    (Windows, ['\\' | '/', ..]) => {
      let root = @winpath.Path(directory).root()
      let prefix = if root.has_suffix("\\") || root.has_suffix("/") {
        root[:root.length() - 1]
      } else {
        root
      }
      prefix.to_owned() + path
    }
    _ => {
      let separator = if directory.has_suffix("/") ||
        (@async.platform is Windows && directory.has_suffix("\\")) {
        ""
      } else {
        @path.sep.to_string()
      }
      directory + separator + path
    }
  }
}

///|
// The published Wasmoon continuation API retries a suspended host call.
// Keep its result until that retry so side effects execute exactly once.
fn Host::suspend(
  self : Host,
  action : async () -> Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  if self.ready is Some(result) {
    self.ready = None
    return result
  }
  self.pending = Some(action)
  raise @vm.AsyncHostCallInProgress
}

///|
async fn Host::call(
  self : Host,
  store : @vm.Store,
  instance : @vm.ModuleInstance,
  index : Int32,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] {
  let mut outcome = @executor.call_func_by_index_resumable(
    store,
    instance,
    index,
    args,
    fn(error) {
      if error == @vm.AsyncHostCallInProgress && self.pending is Some(_) {
        Some(1L)
      } else {
        None
      }
    },
    cooperative=true,
  )
  for ;; {
    match outcome {
      Returned(values) => return values
      Suspended(reason, continuation) => {
        errdefer continuation.cancel()
        match reason {
          CooperativeYield => @async.sleep(0)
          HostCall(1L) => {
            guard self.pending is Some(action) else {
              raise @vm.UnhandledSuspension
            }
            self.pending = None
            self.ready = Some(action())
          }
          AtomicWait => @async.sleep(1)
          _ => raise @vm.UnhandledSuspension
        }
        outcome = continuation.continue_execution()
      }
    }
  }
}
