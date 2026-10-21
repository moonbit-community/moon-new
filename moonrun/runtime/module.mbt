///|
/// A validated module. Each run creates fresh guest and host state.
pub struct Module {
  priv code : @wasm.Module
  priv name : String
  priv executable : String?
}

///|
pub fn Module::from_bytes(
  bytes : Bytes,
  name~ : String = "<module>",
) -> Module raise {
  let code = @parser.parse_module(bytes)
  @validator.validate_module(code)
  { code, name, executable: None, }
}

///|
pub fn Module::load_file(path : String) -> Module raise {
  let executable = @path.Path(path).resolve().to_string()
  let module_ = Module::from_bytes(@sys.read_file(path), name=path)
  { ..module_, executable: Some(executable), }
}

///|
/// Execute with isolated arguments, environment, standard streams and cwd.
/// Blocks the calling thread; no async event loop is required.
/// Callbacks receive exact output bytes, without additional line breaks.
/// `stack_size` is the native guest stack budget in KiB (16 MiB by default).
/// `no_stack_trace` omits guest frames from trap messages.
pub fn Module::run(
  self : Module,
  args~ : Array[String] = [],
  env~ : Map[String, String] = @env.get_env_vars(),
  cwd~ : String = @env.current_dir().unwrap_or("."),
  stdin? : () -> Bytes,
  stdout? : (Bytes) -> Unit,
  stderr? : (Bytes) -> Unit,
  test_args? : String,
  control? : RunControl,
  policy? : @policy.Policy,
  stack_size~ : Int64 = 16384L,
  no_stack_trace~ : Bool = false,
) -> @termination.RunOutcome raise {
  guard stack_size > 0L && stack_size <= 9223372036854775807L / 1024L else {
    raise @vm.LinkErrorDetail(
      "stack size must be a positive KiB value that fits in bytes",
    )
  }
  let selection = match test_args {
    Some(text) => Some(parse_test_selection(text))
    None => None
  }
  let linker = @vm.Linker::with_store(@vm.Store::with_c_heap())
  defer linker.close()
  let directory = @sys.realpath(cwd)
  let env = match policy {
    Some(policy) => policy.environment(env)
    None => env
  }
  guard @sys.kind(directory) is Directory else {
    raise @vm.LinkErrorDetail("working directory must be a directory")
  }
  let control = control.unwrap_or_else(() => RunControl())
  guard control.deliver is None else {
    raise @vm.LinkErrorDetail("run control is already attached to a guest")
  }
  let state = @state.Runtime(
    self.name,
    args,
    env,
    directory,
    stdin,
    stdout,
    stderr,
    policy,
    self.executable,
  )
  defer state.close()
  control.deliver = Some(signal => state.async_host.deliver_signal(signal))
  defer {
    control.deliver = None
    state.async_host.shutting_down = true
  }
  let context = @wasmoon.Context(state, poll=() => {
    if control.poll is Some(poll) &&
      poll() is Some(signal) &&
      !control.send_signal(signal) {
      state.async_host.termination_signal = Some(signal)
      raise @vm.HostExit(128 + signal)
    }
  })
  defer context.close()
  let result = context.execute(
    linker,
    self.code,
    selection,
    stack_size=stack_size * 1024L,
    no_stack_trace~,
  )
  if env.contains("MOONBIT_ASYNC_CHECK_FD_LEAK") &&
    state.leak_summary() is Some(summary) {
    state.stdio.output(
      2,
      @utf8.encode("moonrun Runtime leaked host state: \{summary}\n"),
    )
    Exited(101)
  } else {
    result
  }
}
