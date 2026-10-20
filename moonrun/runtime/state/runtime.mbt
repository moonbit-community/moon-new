///|
/// Process-facing state for one execution, composed independently of Wasmoon.
pub struct Runtime {
  args : Array[String]
  env : Map[String, String]
  cwd : String
  executable : String?
  policy : @policy.Policy?
  handles : @handles.Handles
  stdio : @stdio.Stdio
  filesystem : @filesystem.HostFs
  network : @network.HostNetwork
  process : @process.HostProcess
  sqlite : @sqlite.HostSqlite
  async_host : @async_host.AsyncHost
}

///|
pub fn Runtime::Runtime(
  name : String,
  args : Array[String],
  env : Map[String, String],
  cwd : String,
  stdin : (() -> Bytes)?,
  stdout : ((Bytes) -> Unit)?,
  stderr : ((Bytes) -> Unit)?,
  group : @async.TaskGroup[@termination.RunOutcome],
  policy : @policy.Policy?,
  executable : String?,
) -> Runtime {
  let env = @environment.copy_environment(env)
  let handles = @handles.Handles()
  let stdio = @stdio.Stdio(stdin, stdout, stderr)
  let filesystem = @filesystem.HostFs(policy, cwd, stdio, env)
  {
    args: [name, ..args],
    env,
    cwd,
    executable,
    policy,
    handles,
    stdio,
    filesystem,
    sqlite: @sqlite.HostSqlite(filesystem, handles),
    network: @network.HostNetwork(policy, stdio),
    process: @process.HostProcess(policy, stdio, handles, group),
    async_host: @async_host.AsyncHost(handles, stdio, group),
  }
}

///|
pub fn Runtime::close(self : Runtime) -> Unit {
  self.sqlite.release_entered_mutexes()
  self.process.close()
  self.async_host.close()
  self.sqlite.close()
}

///|
pub fn Runtime::leak_summary(self : Runtime) -> String? {
  let host = self.async_host
  let resources = host.fds
    .keys()
    .filter(key => !host.stdio_handles.values().contains(key))
    .count()
  let counts = [
    ("c_buffers", host.buffers.length()),
    ("addr_infos", host.address_info.length()),
    ("io_results", host.io_results.length()),
    ("jobs", host.jobs.length()),
    ("polls", host.buses.length()),
    ("process_argvs", self.process.process_args.length()),
    ("process_envs", self.process.process_env.length()),
    ("resources", resources + self.process.process_handles.length()),
    ("workers", host.workers.length()),
    ("completion_notifier", if host.pool is Some(_) { 1 } else { 0 }),
  ]
  let leaks = counts.filter_map(entry => {
    let (name, count) = entry
    if count == 0 {
      None
    } else {
      Some("\{name}=\{count}")
    }
  })
  let groups = []
  if !leaks.is_empty() {
    groups.push("async(\{leaks.join(", ")})")
  }
  let sqlite = []
  if self.sqlite.databases.length() > 0 {
    sqlite.push("databases=\{self.sqlite.databases.length()}")
  }
  if self.sqlite.statements.length() > 0 {
    sqlite.push("statements=\{self.sqlite.statements.length()}")
  }
  if !sqlite.is_empty() {
    groups.push("sqlite(\{sqlite.join(", ")})")
  }
  if groups.is_empty() {
    None
  } else {
    Some(groups.join(", "))
  }
}
