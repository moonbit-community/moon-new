///|
pub fn resolve_from(directory : String, path : String) -> String {
  // Leave empty names and symlink/.. resolution to the native filesystem.
  match (@async.platform, path) {
    (_, "") => path
    (Windows, ['a'..<='z' | 'A'..<='Z', ':', ..])
    | (Windows, ['\\' | '/', '\\' | '/', ..])
    | (Linux | MacOS, ['/', ..]) => path
    (Windows, ['\\' | '/', ..]) => {
      let root = @winpath.Path(directory).root()
      let prefix = if root.has_suffix("\\") || root.has_suffix("/") {
        root[:root.length() - 1]
      } else {
        root
      }
      prefix.to_owned() + path
    }
    _ => {
      let separator = if directory.has_suffix("/") ||
        (@async.platform is Windows && directory.has_suffix("\\")) {
        ""
      } else {
        @path.sep.to_string()
      }
      directory + separator + path
    }
  }
}
