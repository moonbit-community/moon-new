///|
pub struct HostFs {
  policy : @policy.Policy?
  cwd : String
  priv stdio : @stdio.Stdio
  priv env : Map[String, String]
}

///|
pub fn HostFs::HostFs(
  policy : @policy.Policy?,
  cwd : String,
  stdio : @stdio.Stdio,
  env : Map[String, String],
) -> HostFs {
  { policy, cwd, stdio, env, }
}

///|
pub fn HostFs::resolve(self : HostFs, path : String) -> String {
  @working_directory.resolve_from(self.cwd, path)
}
