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
/// Guest termination is returned to the caller and never exits the host process.
pub(all) enum RunOutcome {
  Completed
  Exited(Int32)
  Signaled(Int32)
  Trapped(String)
} derive(Debug, Eq)

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
  policy? : Policy,
) -> RunOutcome {
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
    let host = Host(
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
    group.add_defer(() => {
      control.deliver = None
      host.close()
    })
    control.deliver = Some(signal => host.deliver_signal(signal))
    defer {
      host.shutting_down = true
    }
    let imports = host.register(linker, self.code)
    let store = linker.get_store()
    // Run start functions through the same cooperative driver as exported entries.
    let instance = @executor.instantiate_module_with_imports_unstarted(
      store,
      self.code,
      imports,
    )
    let outcome = try {
      if self.code.start is Some(index) {
        host.call(store, instance, index, []) |> ignore
      }
      match selection {
        Some(selection) => host.run_tests(store, instance, selection)
        None =>
          for entry in instance.exports {
            if entry.name == "_start" && entry.desc is Func(index) {
              host.call(store, instance, index, []) |> ignore
              break
            }
          }
      }
      Completed
    } catch {
      @vm.HostExit(code) =>
        match host.termination_signal {
          Some(signal) => Signaled(signal)
          None => Exited(code)
        }
      error => {
        let exit = match host.exit_code {
          Some(code) => Some(code)
          None =>
            match host.wasi_context {
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
    outcome
  })
}

///|
pub extend RunOutcome with Debug::{to_repr}

///|
pub extend RunOutcome with Eq::{equal, not_equal}
