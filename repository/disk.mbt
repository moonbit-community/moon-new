///|
// bit's object database requires a synchronous RepoFileSystem. Keep this
// adapter private; project generation continues to use async/fs directly.
priv struct Disk {}

///|
impl @types.RepoFileSystem for Disk with fn read_file(_, path) {
  @sync_fs.read_file_to_bytes(path) catch {
    @sync_fs.IOError(error) =>
      raise @object.GitError::IoError("\{path}: \{error}")
  }
}

///|
impl @types.RepoFileSystem for Disk with fn readdir(_, path) {
  @sync_fs.read_dir(path).to_owned() catch {
    @sync_fs.IOError(error) =>
      raise @object.GitError::IoError("\{path}: \{error}")
  }
}

///|
impl @types.RepoFileSystem for Disk with fn is_dir(_, path) {
  @sync_fs.is_dir(path) catch {
    _ => false
  }
}

///|
impl @types.RepoFileSystem for Disk with fn is_file(_, path) {
  @sync_fs.is_file(path) catch {
    _ => false
  }
}

///|
impl @types.RepoFileSystem for Disk with fn mtime(_, path) {
  // ObjectDb's lazy reads and ref resolution do not inspect working-tree times.
  raise @object.GitError::IoError(
    "Working-tree timestamps are unsupported: \{path}",
  )
}

///|
impl @types.FileSystem for Disk with fn mkdir_p(self, path) {
  if (@sync_fs.is_dir(path) catch { _ => false }) {
    return
  }
  let parent = @path.Path(path).dirname().to_string()
  if parent != path && !parent.is_empty() {
    @types.FileSystem::mkdir_p(self, parent)
  }
  @sync_fs.create_dir(path) catch {
    @sync_fs.IOError(error) =>
      raise @object.GitError::IoError("\{path}: \{error}")
  }
}

///|
impl @types.FileSystem for Disk with fn write_file(_, path, bytes) {
  @sync_fs.write_bytes_to_file(path, bytes) catch {
    @sync_fs.IOError(error) =>
      raise @object.GitError::IoError("\{path}: \{error}")
  }
}

///|
impl @types.FileSystem for Disk with fn write_string(_, path, text) {
  @sync_fs.write_string_to_file(path, text) catch {
    @sync_fs.IOError(error) =>
      raise @object.GitError::IoError("\{path}: \{error}")
  }
}

///|
impl @types.FileSystem for Disk with fn remove_file(_, path) {
  @sync_fs.remove_file(path) catch {
    @sync_fs.IOError(error) =>
      raise @object.GitError::IoError("\{path}: \{error}")
  }
}

///|
impl @types.FileSystem for Disk with fn remove_dir(_, path) {
  @sync_fs.remove_dir(path) catch {
    @sync_fs.IOError(error) =>
      raise @object.GitError::IoError("\{path}: \{error}")
  }
}
