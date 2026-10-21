///|
pub fn Context::execute(
  self : Context,
  linker : @vm.Linker,
  code : @wasm.Module,
  selection : Array[(String, Array[(UInt32, UInt32)])]?,
  stack_size~ : Int64 = 16L * 1024L * 1024L,
  no_stack_trace~ : Bool = false,
) -> @termination.RunOutcome raise {
  let imports = self.register(linker, code)
  let store = linker.get_store()
  // Run start functions through the same cooperative driver as exported entries.
  let instance = @executor.instantiate_module_with_imports_unstarted(
    store, code, imports,
  )
  let jit = prepare_jit(code, store, instance, stack_size)
  defer jit.close()
  jit.install_hostcall_dispatcher(store, instance)
  let outcome : @termination.RunOutcome = try {
    if code.start is Some(index) {
      self.call(jit, store, instance, index, []) |> ignore
    }
    match selection {
      Some(selection) =>
        self.run_tests(jit, store, instance, selection, no_stack_trace)
      None =>
        for entry in instance.exports {
          if entry.name == "_start" && entry.desc is Func(index) {
            self.call(jit, store, instance, index, []) |> ignore
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
        None => Trapped(format_trap(error, jit, no_stack_trace))
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
fn Context::call(
  self : Context,
  jit : @jit_context.JITModuleContext,
  store : @vm.Store,
  instance : @vm.ModuleInstance,
  index : Int32,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let mut yielded_at = @wasi.native_clock_gettime_monotonic()
  let mut outcome = jit.call_core_func_resumable(store, instance, index, args) catch {
    @jit_context.Exit(code) => raise @vm.HostExit(code)
    @jit_context.HostInvocation(error) => raise error
    error => raise error
  }
  for ;; {
    match outcome {
      NativeCoreReturned(values) => return values
      NativeCoreSuspended(reason, continuation) => {
        errdefer continuation.cancel()
        match reason {
          CooperativeYield =>
            if @wasi.native_clock_gettime_monotonic() - yielded_at >= 1000000L {
              self.progress()
              yielded_at = @wasi.native_clock_gettime_monotonic()
            }
          HostCall => raise @vm.UnhandledSuspension
          AtomicWait => {
            self.progress()
            @sys.sleep(1)
          }
        }
        outcome = continuation.continue_execution() catch {
          @jit_context.Exit(code) => raise @vm.HostExit(code)
          @jit_context.HostInvocation(error) => raise error
          error => raise error
        }
      }
    }
  }
}
