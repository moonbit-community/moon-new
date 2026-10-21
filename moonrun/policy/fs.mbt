///|
pub fn policy_path(path : String, entry : Bool) -> String? {
  let parts : Array[String] = []
  let mut current = path
  if entry {
    parts.push(@path.Path(current).basename().to_owned())
    current = @path.Path(current).dirname().to_string()
  }
  for ;; {
    let canonical = Some(@sys.realpath(current)) catch {
      @sys.OSError(_, ..) as error if error.is_ENOENT() => None
      _ => return None
    }
    if canonical is Some(canonical) {
      let mut result = canonical
      for i = parts.length() - 1; i >= 0; i = i - 1 {
        result = @working_directory.resolve_from(result, parts[i])
      }
      return Some(@path.Path(result).normalize().to_string())
    }
    let parent = @path.Path(current).dirname().to_string()
    if parent == current || current.is_empty() {
      return None
    }
    parts.push(@path.Path(current).basename().to_owned())
    current = parent
  }
}

///|
fn policy_root_contains(roots : Array[String], path : String) -> Bool {
  roots.any(root => {
    root == "*" ||
    path == root ||
    path.has_prefix(
      root +
      (if root.has_suffix("/") || root.has_suffix("\\") {
        ""
      } else {
        @path.sep.to_string()
      }),
    )
  })
}

///|
pub fn Policy::allows_path(
  self : Policy,
  path : String,
  read~ : Bool,
  write~ : Bool,
) -> Bool {
  (!read || policy_root_contains(self.read, path)) &&
  (!write || policy_root_contains(self.write, path))
}
