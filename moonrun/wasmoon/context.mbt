///|
/// Wasmoon-owned values and continuation state for one run.
pub struct Context {
  priv runtime : @state.Runtime
  priv values : Array[HostValue]
  priv mut pending : (async () -> Array[@wasm.Value])?
  priv mut ready : Array[@wasm.Value]?
  priv mut exit_code : Int32?
  priv mut wasi_context : @wasi.WasiContext?
  priv mut ffi_memory : @vm.Memory?
  priv filesystem_results : @filesystem.OperationResults
  priv sanitizer_objects : Map[UInt32, UInt32]
}

///|
pub fn Context::Context(runtime : @state.Runtime) -> Context {
  {
    runtime,
    values: [],
    pending: None,
    ready: None,
    exit_code: None,
    wasi_context: None,
    ffi_memory: None,
    filesystem_results: @filesystem.OperationResults(),
    sanitizer_objects: Map([]),
  }
}

///|
pub fn Context::close(self : Context) -> Unit {
  if self.wasi_context is Some(context) {
    let descriptors = context.open_files.keys().collect()
    for fd in descriptors {
      ignore(context.close_fd(fd))
    }
  }
  self.values.clear()
  self.pending = None
  self.ready = None
}
