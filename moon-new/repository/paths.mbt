///|
fn git_directory(
  disk : Disk,
  root : String,
) -> (String, Bool)? raise @object.GitError {
  let marker = root + "/.git"
  if @types.RepoFileSystem::is_file(disk, marker) {
    let text = @utf8.decode(@types.RepoFileSystem::read_file(disk, marker)) catch {
      error =>
        raise @object.GitError::InvalidObject(
          "Invalid Git directory file \{marker}: \{error}",
        )
    }
    let line = text.trim()
    if line.has_prefix("gitdir: ") {
      let target = line[8:].trim().to_owned()
      // bit 0.48 only recognizes '/' as absolute here; Path also handles
      // Windows drive roots and UNC paths emitted by git worktree.
      if @path.Path(target).is_absolute() {
        return Some((target, false))
      }
    }
  }
  @git.detect_git_dir(disk, root)
}
