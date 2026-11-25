///|
fn has_windows_drive(path : String) -> Bool {
  @path.sep == '\\' && path is [letter, ':', ..] && letter.is_ascii_alphabetic()
}

///|
/// Append a relative component without normalizing away symlink-sensitive `..`.
fn join_path(parent : String, child : String) -> String {
  guard !parent.is_empty() else { child }
  guard !(has_windows_drive(parent) && parent.length() == 2) else {
    parent + child
  }
  let separator = @path.sep.to_string()
  if parent is [.., last] &&
    (last == @path.sep || (@path.sep == '\\' && last == '/')) {
    parent + child
  } else {
    parent + separator + child
  }
}

///|
fn destination_path(path : String) -> String {
  let separators = if @path.sep == '\\' { "/\\" } else { "/" }
  let trimmed = path[:].trim_end(chars=separators).to_owned()
  if trimmed.is_empty() || (@path.sep == '\\' && trimmed.has_suffix(":")) {
    path
  } else {
    trimmed
  }
}

///|
fn inferred_name(destination : String) -> String {
  let has_root_or_prefix = @path.Path(destination).is_absolute() ||
    has_windows_drive(destination) ||
    (@path.sep == '\\' && destination is ['/' | '\\', ..])
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
  if basename.is_empty() || basename == ".." {
    return "hello"
  }
  match basename.rev_split_once(".") {
    Some((stem, _)) if !stem.is_empty() => stem.to_owned()
    _ => basename.to_owned()
  }
}
