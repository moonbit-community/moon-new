///|
pub fn HostFs::temporary_path(self : HostFs) -> String raise @sys.HostError {
  let from_env = if @sys.platform is Windows {
    match
      @environment.environment_entry(self.env, "TMP")
      .map(entry => entry.1)
      .filter(path => !path.is_empty()) {
      Some(path) => Some(path)
      None =>
        @environment.environment_entry(self.env, "TEMP")
        .map(entry => entry.1)
        .filter(path => !path.is_empty())
    }
  } else {
    self.env.get("TMPDIR").filter(path => !path.is_empty())
  }
  let path = match from_env {
    Some(path) => path
    None => {
      let buffer = @sys.copy_tmp_path(@sys.native_tmp_path())
      guard !buffer.is_empty() else {
        raise @sys.Operation("failed to obtain temporary directory")
      }
      if @sys.platform is Windows {
        @utf16.decode(buffer, endianness=Little) catch {
          _ => raise @sys.Invalid
        }
      } else {
        @utf8.decode(buffer) catch {
          _ => raise @sys.Invalid
        }
      }
    }
  }
  if path.has_suffix("/") || (@sys.platform is Windows && path.has_suffix("\\")) {
    path
  } else {
    path + (if @sys.platform is Windows { "\\" } else { "/" })
  }
}
