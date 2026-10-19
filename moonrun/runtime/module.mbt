///|
/// A validated module. Each run creates fresh guest and host state.
pub struct Module {
  priv code : @wasm.Module
  priv name : String
}

///|
pub fn Module::from_bytes(
  bytes : Bytes,
  name~ : String = "<module>",
) -> Module raise {
  let code = @parser.parse_module(bytes)
  @validator.validate_module(code)
  { code, name, }
}

///|
pub async fn Module::load_file(path : String) -> Module {
  Module::from_bytes(@fs.read_file(path).binary(), name=path)
}

///|
/// Execute with isolated arguments, environment, standard streams and cwd.
/// Callbacks receive exact output bytes, without additional line breaks.
pub async fn Module::run(
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
) -> @termination.RunOutcome {
  let selection = match test_args {
    Some(text) => Some(parse_test_selection(text))
    None => None
  }
  let linker = @vm.Linker()
  defer linker.close()
  let directory = @fs.realpath(cwd)
  let env = match policy {
    Some(policy) => policy.environment(env)
    None => env
  }
  guard @fs.kind(directory) is Directory else {
    raise @vm.LinkErrorDetail("working directory must be a directory")
  }
  @async.with_task_group(group => {
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
      group,
      policy,
    )
    let context = @wasmoon.Context(state)
    group.add_defer(() => {
      control.deliver = None
      state.close()
      context.close()
    })
    control.deliver = Some(signal => state.async_host.deliver_signal(signal))
    defer {
      state.async_host.shutting_down = true
    }
    context.execute(linker, self.code, selection)
  })
}
