///|
pub struct CreatedProject {
  username : String
  name : String
  warnings : Array[String]
  git_stdout : String
  git_stderr : String
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
async fn ensure_directory(
  path : String,
  filesystem : FileSystem,
  created : Array[CreatedPath],
) -> Unit {
  match (filesystem.kind)(path) {
    Some(Directory | SymLink) => return
    Some(_) => raise CreationError("Not a directory: \{path}")
    None => ()
  }
  let parent = @path.Path(path).dirname().to_string()
  if parent != path && parent != "" {
    ensure_directory(parent, filesystem, created)
  }
  // Creating an ancestor may have made a `..` component resolvable.
  if (filesystem.kind)(path) is Some(Directory | SymLink) {
    return
  }
  (filesystem.mkdir)(path)
  created.push(Directory(path))
}

///|
async fn write_new(
  path : String,
  content : String,
  filesystem : FileSystem,
  created : Array[CreatedPath],
) -> Unit {
  let file = (filesystem.create)(path)
  created.push(File(path))
  defer (file.close)()
  (file.write)(content)
}

///|
async fn check_destination(
  destination : String,
  filesystem : FileSystem,
) -> Unit {
  match (filesystem.kind)(destination) {
    None => ()
    Some(Directory) =>
      if !(filesystem.entries)(destination).is_empty() {
        raise CreationError("Destination is not empty: \{destination}")
      }
    Some(_) =>
      raise CreationError(
        "Destination must be a directory, not a file or symbolic link: \{destination}",
      )
  }
}

///|
/// Create only in an absent or empty directory. The supplied filesystem is the
/// agreed fault-injection boundary; normal callers use the real implementation.
pub async fn create(
  destination : String,
  user? : String,
  name? : String,
  filesystem? : FileSystem = FileSystem::real(),
) -> CreatedProject {
  let warnings : Array[String] = []
  let username = match user {
    Some(user) => user
    None => existing_username(warnings).unwrap_or("username")
  }
  let name = name.unwrap_or_else(() => inferred_name(destination))
  validate_names(username, name, warnings)
  let entries = @template.render(username, name)
  let destination = destination_path(destination)
  check_destination(destination, filesystem)
  let created : Array[CreatedPath] = []
  try {
    ensure_directory(destination, filesystem, created)
    // Missing ancestors can initially hide an existing target behind `..`.
    // Recheck its resolved eligibility before writing any template files.
    check_destination(destination, filesystem)
    for entry in entries {
      match entry {
        File(path~, content~, executable~) => {
          let path = join_path(destination, path)
          ensure_directory(
            @path.Path(path).dirname().to_string(),
            filesystem,
            created,
          )
          write_new(path, content, filesystem, created)
          if executable && !(@async.platform is Windows) {
            (filesystem.chmod)(path, 0o755) catch {
              err => warnings.push("Could not make \{path} executable: \{err}")
            }
          }
        }
        Link(path~, target~) => {
          let path = join_path(destination, path)
          try {
            (filesystem.symlink)(path, target)
            created.push(File(path))
          } catch {
            err => {
              warnings.push(
                "Could not create symbolic link \{path}; copying instead: \{err}",
              )
              let mut content = None
              for entry in entries {
                if entry is File(path=file_path, content=text, ..) &&
                  file_path == target {
                  content = Some(text)
                  break
                }
              }
              guard content is Some(text) else {
                raise CreationError("Missing bundled link target: \{target}")
              }
              write_new(path, text, filesystem, created)
            }
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
            File(path) => (filesystem.remove)(path)
            Directory(path) => (filesystem.rmdir)(path)
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
      let cleanup = if residual.is_empty() {
        ""
      } else {
        "\nCleanup failed; paths may remain:\n" + residual.join("\n")
      }
      raise CreationError("Could not create \{destination}: \{error}\{cleanup}")
    }
  }
  let (git_stdout, git_stderr) = initialize_git(destination, warnings)
  { username, name, warnings, git_stdout, git_stderr, }
}

///|
pub impl Show for CreationError with fn output(self, logger) {
  let CreationError(message) = self
  logger.write_string(message)
}

///|
pub extend CreationError with Show::{to_string, output}
