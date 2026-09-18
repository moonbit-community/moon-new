///|
fn root() -> String {
  @env.get_env_var("MOON_NEW_TEST_ROOT").unwrap_or(@env.current_dir().unwrap())
}

///|
fn windows() -> Bool {
  @path.sep == '\\'
}

///|
struct Sandbox {
  root : String
  env : Map[String, String]
}

///|
async fn Sandbox::new() -> Sandbox {
  let root = @fs.tmpdir(prefix="moon-new-cli-")
  let env : Map[String, String] = Map([])
  for key, value in @env.get_env_vars() {
    // Windows environment keys are case-insensitive, unlike MoonBit map keys.
    env[if windows() { key.to_upper() } else { key }] = value
  }
  env["MOON_HOME"] = root + "/moon-home"
  { root, env, }
}

///|
struct Output {
  status : Int
  stdout : String
  stderr : String
} derive(Debug)

///|
async fn command(
  program : String,
  args : Array[String],
  cwd~ : String,
  env? : Map[String, String],
) -> Output {
  let (status, stdout, stderr) = @process.collect_output(
    program,
    args,
    cwd~,
    extra_env=env.unwrap_or({}),
    inherit_env=env is None,
  )
  { status, stdout: stdout.text(), stderr: stderr.text(), }
}

///|
async fn checked(
  program : String,
  args : Array[String],
  cwd~ : String,
) -> String {
  let result = command(program, args, cwd~)
  assert_eq(result.status, 0, msg=result.stderr + result.stdout)
  result.stdout
}

///|
async fn cli_command() -> (String, Array[String]) {
  let target = @env.get_env_var("MOON_NEW_TEST_TARGET").unwrap_or("native")
  if target == "native" {
    (@fs.realpath(root() + "/_build/native/debug/build/moon-new.exe"), [])
  } else {
    assert_eq(target, "wasm")
    // Resolve the runner before tests clear the child PATH to hide Git.
    let executable = if windows() { "moonrun.exe" } else { "moonrun" }
    let separator = if windows() { ";" } else { ":" }
    for directory in @env.get_env_var("PATH").unwrap_or("").split(separator) {
      let path = directory.to_owned() + "/" + executable
      if @fs.exists(path) {
        return (
          @fs.realpath(path),
          [root() + "/_build/wasm/debug/build/moon-new.wasm", "--"],
        )
      }
    }
    fail("moonrun not found on PATH")
  }
}

///|
async fn Sandbox::run(self : Sandbox, args : Array[String]) -> Output {
  let (program, prefix) = cli_command()
  command(program, prefix + args, cwd=self.root, env=self.env)
}

///|
async fn Sandbox::read(self : Sandbox, path : String) -> String {
  @fs.read_file(self.root + "/" + path).text()
}

///|
async fn Sandbox::exists(self : Sandbox, path : String) -> Bool {
  @fs.exists(self.root + "/" + path)
}

///|
async fn files(directory : String, prefix? : String = "") -> Array[String] {
  let result = []
  for name in @fs.readdir(directory, include_hidden=true) {
    if name == ".git" {
      continue
    }
    let relative = prefix + name
    if @fs.kind(directory + "/" + name, follow_symlink=false) == Directory {
      result.append(files(directory + "/" + name, prefix=relative + "/"))
    } else {
      result.push(relative)
    }
  }
  result.sort()
  result
}

///|
async fn directory_link(target : String, link : String) -> Bool {
  try {
    @fs.symlink(target~, link, force_symlink=true)
    true
  } catch {
    error =>
      if windows() {
        println("SKIP directory symlinks unavailable: \{error}")
        false
      } else {
        raise error
      }
  }
}

///|
async fn permission(path : String) -> String {
  let system = checked("uname", [], cwd=root())
  let args = if system.trim() == "Darwin" {
    ["-f", "%Lp", path]
  } else {
    ["-c", "%a", path]
  }
  checked("stat", args, cwd=root()).trim().to_owned()
}
