///|
/// Initialize an empty repository unless already inside a working tree.
/// Return whether a new repository was initialized. No hooks, global Git
/// configuration, credentials, or external commands are used.
pub async fn initialize(destination : String) -> Bool {
  let disk = Disk::{ }
  let root = @fs.realpath(destination)
  let mut current = root
  while true {
    if git_directory(disk, current) is Some((git_dir, false)) &&
      @types.RepoFileSystem::is_file(disk, git_dir + "/HEAD") &&
      @types.RepoFileSystem::is_dir(
        disk,
        @git.resolve_common_git_dir(disk, git_dir) + "/objects",
      ) {
      return false
    }
    let parent = @path.Path(current).dirname().to_string()
    if parent == current || parent == "" {
      break
    }
    current = parent
  }
  @git.init_repo(disk, root)
  true
}
