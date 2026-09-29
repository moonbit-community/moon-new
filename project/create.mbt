///|
pub struct CreatedProject {
  username : String
  name : String
  git_initialized : Bool
}

///|
pub(all) suberror CreationError {
  CreationError(String)
}

///|
priv enum CreatedPath {
  File(String)
  Directory(String)
}

///|
async fn existing_kind(path : String) -> @fs.FileKind? {
  Some(@fs.kind(path, follow_symlink=false)) catch {
    @os_error.OSError(_) as err if err.is_ENOENT() => None
    err => raise err
  }
}

///|
async fn ensure_directory(path : String, created : Array[CreatedPath]) -> Unit {
  match existing_kind(path) {
    Some(Directory | SymLink) => return
    Some(_) => raise CreationError("Not a directory: \{path}")
    None => ()
  }
  let parent = @path.Path(path).dirname().to_string()
  if parent != path && parent != "" {
    ensure_directory(parent, created)
  }
  // Creating an ancestor may have made a `..` component resolvable.
  if existing_kind(path) is Some(Directory | SymLink) {
    return
  }
  @fs.mkdir(path, permission=0o777)
  created.push(Directory(path))
}

///|
async fn write_new(
  path : String,
  content : Bytes,
  created : Array[CreatedPath],
  executable~ : Bool,
  warnings~ : Array[String],
) -> Unit {
  let file = @fs.open(
    path,
    mode=WriteOnly,
    create_mode=CreateNew,
    permission=0o666,
  )
  created.push(File(path))
  defer file.close()
  file.write(content)
  if executable && !(@async.platform is Windows) {
    @fs.chmod(path, 0o755) catch {
      err => warnings.push("Could not make \{path} executable: \{err}")
    }
  }
}

///|
async fn check_destination(destination : String) -> Unit {
  match existing_kind(destination) {
    None => ()
    Some(Directory) =>
      if !@fs.readdir(destination, include_hidden=true).is_empty() {
        raise CreationError("Destination is not empty: \{destination}")
      }
    Some(_) =>
      raise CreationError(
        "Destination must be a directory, not a file or symbolic link: \{destination}",
      )
  }
}

///|
/// Create only in an absent or empty directory.
/// Supply a warnings array to collect diagnostics on both success and failure.
pub async fn create(
  destination : String,
  user? : String,
  name? : String,
  template? : String,
  subdir? : String,
  branch? : String,
  tag? : String,
  rev? : String,
  warnings? : Array[String] = [],
) -> CreatedProject {
  let username = match user {
    Some(user) => user
    None => existing_username(warnings).unwrap_or("username")
  }
  let name = name.unwrap_or_else(() => inferred_name(destination))
  validate_names(username, name, warnings)
  let entries = match template {
    Some(source) =>
      @template.render_repository(
        @repository.load(
          source,
          branch?,
          tag?,
          rev?,
          subdir=subdir.unwrap_or(""),
        ),
        username,
        name,
        warnings~,
      )
    None => {
      if subdir is Some(_) ||
        branch is Some(_) ||
        tag is Some(_) ||
        rev is Some(_) {
        raise CreationError("Repository options require --template")
      }
      @template.render(username, name)
    }
  }
  let destination = destination_path(destination)
  check_destination(destination)
  let created : Array[CreatedPath] = []
  try {
    ensure_directory(destination, created)
    // Missing ancestors can initially hide an existing target behind `..`.
    // Recheck its resolved eligibility before writing any template files.
    check_destination(destination)
    let inventory : Map[String, @template.Entry] = Map([])
    for entry in entries {
      let path = match entry {
        File(path~, ..) | Link(path~, ..) => path
      }
      inventory[path] = entry
      // Create every parent before any links, so filesystem aliases cannot
      // redirect a later output through a previously generated symlink.
      ensure_directory(
        @path.Path(join_path(destination, path)).dirname().to_string(),
        created,
      )
    }
    // Write regular files first. Link fallbacks use the inventory even when the
    // referenced link or directory has not been materialized yet.
    for entry in entries {
      if entry is File(path~, content~, executable~) {
        let path = join_path(destination, path)
        write_new(path, content, created, executable~, warnings~)
      }
    }
    for entry in entries {
      if entry is Link(path=relative, target~) {
        let path = join_path(destination, relative)
        try {
          @fs.symlink(target~, path, force_symlink=true)
          created.push(File(path))
        } catch {
          err => {
            // A case-folded alias may already exist on this filesystem.
            // Never treat a collision as permission to copy through that path.
            if existing_kind(path) is Some(_) {
              raise CreationError(
                "Output path collision at \{relative}: \{err}",
              )
            }
            warnings.push(
              "Could not create symbolic link \{path}; copying instead: \{err}",
            )
            if target.has_prefix("/") ||
              target.contains("\\") ||
              target.contains(":") ||
              target == "" {
              raise CreationError(
                "Invalid or external symbolic-link copy target: \{relative}",
              )
            }
            let parent = relative.split("/").to_array()
            ignore(parent.pop())
            let prefix = parent.map(part => part.to_owned()).join("/")
            let source = (if prefix == "" { "" } else { prefix + "/" }) + target
            copy_target(source, path, inventory, created, warnings, [])
          }
        }
      }
    }
  } catch {
    error => {
      let residual : Array[String] = []
      for entry in created.rev_iter() {
        try {
          match entry {
            File(path) => @fs.remove(path)
            Directory(path) => @fs.rmdir(path)
          }
        } catch {
          cleanup_error => {
            let path = match entry {
              File(path) | Directory(path) => path
            }
            residual.push("\{path}: \{cleanup_error}")
          }
        }
      }
      if residual.is_empty() {
        raise error
      }
      let cleanup = "\nCleanup failed; paths may remain:\n" +
        residual.join("\n")
      raise CreationError("Could not create \{destination}: \{error}\{cleanup}")
    }
  }
  let git_initialized = initialize_git(destination, warnings)
  { username, name, git_initialized, }
}

///|
pub impl Show for CreationError with fn output(self, logger) {
  let CreationError(message) = self
  logger.write_string(message)
}

///|
pub extend CreationError with Show::{to_string, output}
