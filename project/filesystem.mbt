///|
/// A newly created file. Creation is separate from writing so rollback owns a
/// file even if the first write fails after leaving partial contents.
pub(all) struct OutputFile {
  write : async (String) -> Unit
  close : () -> Unit
}

///|
/// The filesystem boundary used by creation and deterministic failure tests.
pub(all) struct FileSystem {
  kind : async (String) -> @fs.FileKind?
  entries : async (String) -> Array[String]
  mkdir : async (String) -> Unit
  create : async (String) -> OutputFile
  symlink : async (String, String) -> Unit
  chmod : async (String, Int) -> Unit
  remove : async (String) -> Unit
  rmdir : async (String) -> Unit
}

///|
pub fn FileSystem::real() -> FileSystem {
  {
    kind: async fn(path) {
      Some(@fs.kind(path, follow_symlink=false)) catch {
        @os_error.OSError(_) as err if err.is_ENOENT() => None
        err => raise err
      }
    },
    entries: async fn(path) { @fs.readdir(path, include_hidden=true) },
    mkdir: async fn(path) { @fs.mkdir(path, permission=0o777) },
    create: async fn(path) {
      let file = @fs.open(
        path,
        mode=WriteOnly,
        create_mode=CreateNew,
        permission=0o666,
      )
      { write: async fn(text) { file.write(text) }, close: () => file.close(), }
    },
    symlink: async fn(path, target) {
      @fs.symlink(target~, path, force_symlink=true)
    },
    chmod: async fn(path, mode) { @fs.chmod(path, mode) },
    remove: async fn(path) { @fs.remove(path) },
    rmdir: async fn(path) { @fs.rmdir(path) },
  }
}
