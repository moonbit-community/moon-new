///|
/// Resolve against the rendered inventory, never the destination filesystem.
/// Follow links before processing later ".." components, like path traversal.
fn resolve_copy_target(
  path : String,
  entries : Map[String, @template.Entry],
  links : Array[String],
) -> String raise CreationError {
  if path.has_prefix("/") ||
    path.contains("\\") ||
    path.contains(":") ||
    path.contains("\u0000") ||
    path == "" {
    raise CreationError(
      "Invalid or external symbolic-link copy target: \{path}",
    )
  }
  let parts = path.split("/").map(part => part.to_owned()).to_array()
  let resolved : Array[String] = []
  for i, part in parts {
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      if resolved.is_empty() {
        raise CreationError("Symbolic-link copy target escapes the project")
      }
      ignore(resolved.pop())
      continue
    }
    resolved.push(part)
    let current = resolved.join("/")
    match entries.get(current) {
      Some(Link(target~, ..)) => {
        if links.contains(current) {
          raise CreationError("Cyclic symbolic-link copy target: \{current}")
        }
        ignore(resolved.pop())
        if target.has_prefix("/") ||
          target.contains("\\") ||
          target.contains(":") ||
          target == "" {
          raise CreationError(
            "Invalid or external symbolic-link copy target: \{current}",
          )
        }
        let parent = resolved.join("/")
        let next = (if parent == "" { "" } else { parent + "/" }) + target
        let target = resolve_copy_target(next, entries, links + [current])
        if entries.get(target) is Some(File(..)) && i != parts.length() - 1 {
          raise CreationError(
            "Not a directory in symbolic-link copy target: \{current}",
          )
        }
        resolved.clear()
        if target != "" {
          resolved.append(
            target.split("/").map(part => part.to_owned()).to_array(),
          )
        }
      }
      Some(File(..)) =>
        if i != parts.length() - 1 {
          raise CreationError(
            "Not a directory in symbolic-link copy target: \{current}",
          )
        }
      None =>
        if !entries.keys().any(key => key.has_prefix(current + "/")) {
          raise CreationError("Missing symbolic-link copy target: \{current}")
        }
    }
  }
  resolved.join("/")
}

///|
/// Materialize a file or directory solely from rendered project contents.
async fn copy_target(
  source : String,
  destination : String,
  entries : Map[String, @template.Entry],
  created : Array[CreatedPath],
  warnings : Array[String],
  ancestors : Array[String],
) -> Unit {
  let source = resolve_copy_target(source, entries, [])
  if ancestors.contains(source) {
    raise CreationError("Cyclic directory copy target: \{source}")
  }
  match entries.get(source) {
    Some(File(content~, executable~, ..)) =>
      write_new(destination, content, created, executable~, warnings~)
    Some(Link(..)) =>
      raise CreationError("Unresolved symbolic-link copy target: \{source}")
    None => {
      ensure_directory(destination, created)
      let prefix = if source == "" { "" } else { source + "/" }
      let children : Set[String] = Set([])
      for path in entries.keys() {
        if path.has_prefix(prefix) {
          let child = path[prefix.length():].split("/").to_array()[0].to_owned()
          children.add(child)
        }
      }
      for child in children {
        copy_target(
          prefix + child,
          join_path(destination, child),
          entries,
          created,
          warnings,
          ancestors + [source],
        )
      }
    }
  }
}
