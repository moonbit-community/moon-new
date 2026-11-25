///|
/// Initialize an empty repository unless already inside a working tree.
/// Read the user's Git initialization settings without invoking Git.
pub async fn initialize(
  destination : String,
  warnings~ : Array[String] = [],
) -> Bool {
  let disk = Disk::{ }
  let root = @fs.realpath(destination)
  for current = root {
    if git_directory(disk, current) is Some((git_dir, false)) &&
      @types.RepoFileSystem::is_file(disk, git_dir + "/HEAD") &&
      @types.RepoFileSystem::is_dir(
        disk,
        @git.resolve_common_git_dir(disk, git_dir) + "/objects",
      ) {
      return false
    }
    let parent = @path.Path(current).dirname().to_string()
    if parent == current || parent.is_empty() {
      break
    }
    continue parent
  }
  let home = git_home()
  let config = read_init_config(disk, home)
  let overrides = read_init_overrides()
  let template = match
    (
      @env.get_env_var("GIT_TEMPLATE_DIR"),
      overrides.get("templatedir"),
      config.get("templatedir"),
    ) {
    (Some(path), _, _) => Some(path)
    (_, Some(path), _) | (_, _, Some(path)) =>
      if home is Some(home) && path.strip_prefix("~/") is Some(relative) {
        // Preserve path components for the filesystem to resolve.
        Some("\{home}/\{relative}")
      } else {
        Some(path)
      }
    _ => None
  }
  let git_dir = root + "/.git"
  @fs.mkdir(git_dir, permission=0o777)
  errdefer (@fs.rmdir(git_dir, recursive=true) catch { _ => () })
  if template is Some(path) && !path.is_empty() {
    let path = if @path.Path(path).is_absolute() {
      path
    } else {
      root + "/" + path
    }
    if @types.RepoFileSystem::is_dir(disk, path) {
      copy_git_template(path, git_dir)
    } else {
      warnings.push("Git template directory not found: \{path}")
    }
  }
  let config_path = git_dir + "/config"
  // The copied template config takes precedence over global config.
  let branch = if overrides.get("defaultbranch") is Some(branch) {
    branch
  } else if read_init_value(disk, config_path, "defaultbranch") is Some(branch) {
    branch
  } else {
    config.get("defaultbranch").unwrap_or("main")
  }
  let has_head = @types.RepoFileSystem::is_file(disk, git_dir + "/HEAD")
  guard has_head || @object.check_refname_format("refs/heads/" + branch) else {
    raise @object.GitError::IoError("Invalid Git initial branch: \{branch}")
  }
  let template_config = if @fs.exists(config_path) {
    Some(@fs.read_file(config_path).binary())
  } else {
    None
  }
  let opts = @git.InitOptions::new()
  @git.init_repo_with_options(disk, root, {
    ..opts,
    default_branch: branch,
    template_dir: template,
    is_reinit: has_head,
  })
  if template_config is Some(content) {
    // Keep the template's settings and give the generated core settings priority.
    let generated = @fs.read_file(config_path).binary()
    @fs.write_file(config_path, content + b"\n" + generated)
  }
  true
}

///|
async fn copy_git_template(source : String, destination : String) -> Unit {
  for name in @fs.readdir(source) {
    if name.has_prefix(".") {
      continue
    }
    let from = source + "/" + name
    let to = destination + "/" + name
    match @fs.kind(from, follow_symlink=false) {
      Directory => {
        @fs.mkdir(to, permission=0o777)
        copy_git_template(from, to)
      }
      Regular => {
        let permission = if @async.platform is Windows || !@fs.can_execute(from) {
          0o666
        } else {
          0o777
        }
        @fs.write_file(
          to,
          @fs.read_file(from),
          create_mode=CreateNew,
          permission~,
        )
      }
      _ => ()
    }
  }
}
