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
pub async fn Module::load_file(path : String) -> Module {
  let executable = @path.Path(path).resolve().to_string()
  let module_ = Module::from_bytes(@fs.read_file(path).binary(), name=path)
  { ..module_, executable: Some(executable), }
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
  let leaked = Ref(false)
  let result = @async.with_task_group(group => {
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
      self.executable,
    )
    let context = @wasmoon.Context(state)
    group.add_defer(() => {
      control.deliver = None
      defer {
        state.close()
        context.close()
      }
      if env.contains("MOONBIT_ASYNC_CHECK_FD_LEAK") &&
        state.leak_summary() is Some(summary) {
        leaked.val = true
        @async.protect_from_cancel(() => {
          state.stdio.output(
            2,
            @utf8.encode("moonrun Runtime leaked host state: \{summary}\n"),
          )
        })
      }
    })
    control.deliver = Some(signal => state.async_host.deliver_signal(signal))
    defer {
      state.async_host.shutting_down = true
      state.sqlite.release_entered_mutexes()
    }
    context.execute(linker, self.code, selection)
  })
  if leaked.val {
    Exited(101)
  } else {
    result
  }
}
