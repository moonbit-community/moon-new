///|
fn has_windows_drive(path : String) -> Bool {
  if @path.sep != '\\' {
    return false
  }
  match path[:] {
    [letter, ':', ..] =>
      (letter >= 'a' && letter <= 'z') || (letter >= 'A' && letter <= 'Z')
    _ => false
  }
}

///|
/// Append a relative component without normalizing away symlink-sensitive `..`.
fn join_path(parent : String, child : String) -> String {
  if parent == "" || (has_windows_drive(parent) && parent.length() == 2) {
    return parent + child
  }
  let separator = @path.sep.to_string()
  if parent.has_suffix(separator) ||
    (@path.sep == '\\' && parent.has_suffix("/")) {
    parent + child
  } else {
    parent + separator + child
  }
}

///|
fn destination_path(path : String) -> String {
  let separators = if @path.sep == '\\' { "/\\" } else { "/" }
  let trimmed = path[:].trim_end(chars=separators).to_owned()
  if trimmed == "" || (@path.sep == '\\' && trimmed.has_suffix(":")) {
    path
  } else {
    trimmed
  }
}

///|
fn inferred_name(destination : String) -> String {
  let has_root_or_prefix = @path.Path(destination).is_absolute() ||
    has_windows_drive(destination) ||
    (
      @path.sep == '\\' &&
      (destination.has_prefix("/") || destination.has_prefix("\\"))
    )
  let mut path = if has_root_or_prefix {
    destination
  } else {
    join_path(@env.current_dir().unwrap_or(""), destination)
  }
  // Rust Components ignores trailing `.` components, but not `..`.
  while @path.Path(path).basename() == "." {
    let parent = @path.Path(path).dirname().to_string()
    if parent == path {
      return "hello"
    }
    path = parent
  }
  let basename = @path.Path(path).basename()
  if basename == "" || basename == ".." {
    return "hello"
  }
  match basename.rev_split_once(".") {
    Some((stem, _)) if stem != "" => stem.to_owned()
    _ => basename.to_owned()
  }
}
