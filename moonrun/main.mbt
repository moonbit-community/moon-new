///|
async fn main {
  let inherited_policy = if @env.get_env_var("MOONRUN_INHERITED_POLICY")
    is Some(token) {
    @env.unset_env_var("MOONRUN_INHERITED_POLICY")
    Some(@runtime.Policy::from_inherited_handle(token)) catch {
      error => {
        @stdio.stderr.write("Error: inherited policy: \{error}\n")
        @sys.exit(2)
        return
      }
    }
  } else {
    None
  }
  let args = @env.args()[1:].to_owned()
  if args.is_empty() {
    @stdio.stderr.write("Error: a Wasm path is required\n")
    @sys.exit(2)
    return
  }
  if args[0] == "--help" || args[0] == "-h" {
    @stdio.stdout.write(
      "Usage: moonrun [OPTIONS] <PATH> [ARGS]...\n\nOptions:\n  --test-args <JSON>  Execute MoonBit tests\n  --policy <PATH>    Restrict core/async host access (WASI is not covered)\n  --policy-source-dir <PATH>  Resolve relative policy filesystem roots here\n  --no-stack-trace    Omit guest stack traces\n  -h, --help         Print help\n  -V, --version      Print version\n",
    )
    return
  }
  if args[0] == "--version" || args[0] == "-V" {
    @stdio.stdout.write("moonrun 0.1.0 (Wasmoon)\n")
    return
  }
  let mut path = None
  let mut test_args = None
  let mut policy_path = None
  let mut policy_source_dir = None
  let guest_args = []
  let mut after_separator = false
  for i = 0; i < args.length(); {
    let arg = args[i]
    if after_separator {
      if path is None {
        path = Some(arg)
      } else {
        guest_args.push(arg)
      }
    } else if arg == "--" {
      after_separator = true
    } else if arg.has_prefix("--policy=") {
      policy_path = Some(arg[9:].to_owned())
    } else if arg.has_prefix("--policy-source-dir=") {
      policy_source_dir = Some(arg[20:].to_owned())
    } else if arg == "--policy" || arg == "--policy-source-dir" {
      guard args.get(i + 1) is Some(value) else {
        @stdio.stderr.write("Error: \{arg} requires a value\n")
        @sys.exit(2)
        return
      }
      if arg == "--policy" {
        policy_path = Some(value)
      } else {
        policy_source_dir = Some(value)
      }
      continue i + 2
    } else if arg == "--stack-size" || arg.has_prefix("--stack-size=") {
      // FIXME: Honor byte-based budgets when Wasmoon exposes accounting:
      // https://github.com/Milky2018/wasmoon/issues/546
      @stdio.stderr.write("Error: \{arg} is not supported by this runner yet\n")
      @sys.exit(2)
      return
    } else if arg.has_prefix("--test-args=") {
      test_args = Some(arg[12:].to_owned())
    } else if arg == "--no-stack-trace" {
      ()
    } else if arg == "--test-args" {
      guard args.get(i + 1) is Some(value) else {
        @stdio.stderr.write("Error: --test-args requires a value\n")
        @sys.exit(2)
        return
      }
      test_args = Some(value)
      continue i + 2
    } else if path is None {
      if arg.has_prefix("-") {
        @stdio.stderr.write("Error: unknown option \{arg}\n")
        @sys.exit(2)
        return
      }
      path = Some(arg)
    } else {
      guest_args.push(arg)
    }
    continue i + 1
  }
  guard path is Some(path) else {
    @stdio.stderr.write("Error: a Wasm path is required\n")
    @sys.exit(2)
    return
  }
  if policy_source_dir is Some(_) && policy_path is None {
    @stdio.stderr.write("Error: --policy-source-dir requires --policy\n")
    @sys.exit(2)
    return
  }
  let code = try {
    let policy = match inherited_policy {
      Some(policy) => Some(policy)
      None =>
        match policy_path {
          Some(path) =>
            Some(
              @runtime.Policy::load_file(path, source_dir?=policy_source_dir),
            )
          None => None
        }
    }
    let program = @runtime.Module::load_file(path)
    match run_cli(program, guest_args, test_args, policy) {
      Completed => 0
      Exited(code) => code
      Signaled(signal) => {
        terminate_by_signal(signal)
        128 + signal
      }
      Trapped(message) => {
        @stdio.stderr.write("Error: \{message}\n")
        1
      }
    }
  } catch {
    error => {
      @stdio.stderr.write("Error: \{error}\n")
      1
    }
  }
  @sys.exit(code)
}
