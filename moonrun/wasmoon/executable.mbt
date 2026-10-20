///|
pub async fn Context::execute(
  self : Context,
  linker : @vm.Linker,
  code : @wasm.Module,
  selection : Array[(String, Array[(UInt32, UInt32)])]?,
) -> @termination.RunOutcome {
  let imports = self.register(linker, code)
  let store = linker.get_store()
  // Run start functions through the same cooperative driver as exported entries.
  let instance = @executor.instantiate_module_with_imports_unstarted(
    store, code, imports,
  )
  let outcome : @termination.RunOutcome = try {
    if code.start is Some(index) {
      self.call(store, instance, index, []) |> ignore
    }
    match selection {
      Some(selection) => self.run_tests(store, instance, selection)
      None =>
        for entry in instance.exports {
          if entry.name == "_start" && entry.desc is Func(index) {
            self.call(store, instance, index, []) |> ignore
            break
          }
        }
    }
    Completed
  } catch {
    @vm.HostExit(code) =>
      match self.runtime.async_host.termination_signal {
        Some(signal) => Signaled(signal)
        None => Exited(code)
      }
    error => {
      let exit = match self.exit_code {
        Some(code) => Some(code)
        None =>
          match self.wasi_context {
            Some(context) => context.get_exit_code()
            None => None
          }
      }
      match exit {
        Some(code) => Exited(code)
        // FIXME: Attach owned guest frames when Wasmoon exposes trap context:
        // https://github.com/Milky2018/wasmoon/issues/547
        None => Trapped("\{error}")
      }
    }
  }
  if outcome is Completed && !self.sanitizer_objects.is_empty() {
    Trapped(self.sanitizer_leak_report())
  } else {
    outcome
  }
}

///|
// The published Wasmoon continuation API retries a suspended host call.
// Keep its result until that retry so side effects execute exactly once.
fn Context::suspend(
  self : Context,
  action : async () -> Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  if self.ready is Some(result) {
    self.ready = None
    return result
  }
  self.pending = Some(action)
  raise @vm.AsyncHostCallInProgress
}

///|
async fn Context::call(
  self : Context,
  store : @vm.Store,
  instance : @vm.ModuleInstance,
  index : Int32,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] {
  let mut yielded_at = @wasi.native_clock_gettime_monotonic()
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
          CooperativeYield =>
            // Bound guest CPU slices while avoiding an event-loop turn for
            // every 1,024-instruction Wasmoon continuation.
            if @wasi.native_clock_gettime_monotonic() - yielded_at >= 1000000L {
              @async.sleep(0)
              yielded_at = @wasi.native_clock_gettime_monotonic()
            }
          HostCall(1L) => {
            guard self.pending is Some(action) else {
              raise @vm.UnhandledSuspension
            }
            self.pending = None
            self.ready = Some(
              action() catch {
                @sys.Invalid => raise @vm.TypeMismatch
                @sys.Bounds => raise @vm.OutOfBoundsMemoryAccess
                @sys.Operation(message) => raise @vm.LinkErrorDetail(message)
                error => raise error
              },
            )
            yielded_at = @wasi.native_clock_gettime_monotonic()
          }
          AtomicWait => @async.sleep(1)
          _ => raise @vm.UnhandledSuspension
        }
        outcome = continuation.continue_execution()
      }
    }
  }
}
