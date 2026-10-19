///|
/// Process-facing state for one execution, composed independently of Wasmoon.
pub struct Runtime {
  args : Array[String]
  env : Map[String, String]
  cwd : String
  policy : @policy.Policy?
  handles : @handles.Handles
  stdio : @stdio.Stdio
  filesystem : @filesystem.HostFs
  network : @network.HostNetwork
  process : @process.HostProcess
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
) -> Runtime {
  let env = @environment.copy_environment(env)
  let handles = @handles.Handles()
  let stdio = @stdio.Stdio(stdin, stdout, stderr)
  {
    args: [name, ..args],
    env,
    cwd,
    policy,
    handles,
    stdio,
    filesystem: @filesystem.HostFs(policy, cwd, stdio, env),
    network: @network.HostNetwork(policy, stdio),
    process: @process.HostProcess(policy, stdio, handles, group),
    async_host: @async_host.AsyncHost(handles, stdio, group),
  }
}

///|
pub fn Runtime::close(self : Runtime) -> Unit {
  self.process.close()
  self.async_host.close()
}
