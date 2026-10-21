///|
pub struct HostProcess {
  priv policy : @policy.Policy?
  priv stdio : @stdio.Stdio
  priv handles : @handles.Handles
  process_env : Map[Int64, Environment]
  process_args : Map[Int64, Array[String?]]
  children : Map[Int32, Child]
  priv owned_children : Array[Child]
  process_handles : Map[Int64, ProcessHandle]
}

///|
pub fn HostProcess::HostProcess(
  policy : @policy.Policy?,
  stdio : @stdio.Stdio,
  handles : @handles.Handles,
) -> HostProcess {
  {
    policy,
    stdio,
    handles,
    process_env: Map([]),
    process_args: Map([]),
    children: Map([]),
    owned_children: [],
    process_handles: Map([]),
  }
}

///|
pub fn HostProcess::close(self : HostProcess) -> Unit {
  for child in self.owned_children {
    child.close()
    for stream in child.streams {
      stream.close()
    }
  }
  self.owned_children.clear()
  self.children.clear()
  for _, handle in self.process_handles {
    if handle is External(process) {
      process.release()
    }
  }
  self.process_handles.clear()
  self.process_env.clear()
  self.process_args.clear()
}
