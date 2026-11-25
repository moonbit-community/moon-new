///|
/// Preserve links when possible; warn and skip unavailable links.
async fn create_link(
  destination : String,
  relative : String,
  target : String,
  created : Array[CreatedPath],
  warnings : Array[String],
) -> Unit {
  let path = join_path(destination, relative)
  try {
    @fs.symlink(target~, path, force_symlink=true)
    created.push(File(path))
  } catch {
    error => {
      // A case-folded alias is still an output collision, not a skipped link.
      if existing_kind(path) is Some(_) {
        raise CreationError("Output path collision at \{relative}: \{error}")
      }
      let hint = if @async.platform is Windows {
        " Enable Developer Mode or run with administrator privileges to allow symbolic links."
      } else {
        ""
      }
      warnings.push(
        "Could not create symbolic link \{path}; skipping: \{error}\{hint}",
      )
    }
  }
}
