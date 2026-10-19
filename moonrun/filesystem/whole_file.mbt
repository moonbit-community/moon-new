///|
pub async fn HostFs::read_file_to_string(
  self : HostFs,
  path : String,
) -> String {
  self.authorize_path(path)
  @utf8.decode(@fs.read_file(path).binary())
}

///|
pub async fn HostFs::read_file_to_bytes(
  self : HostFs,
  path : String,
) -> FixedArray[Byte] {
  self.authorize_path(path)
  @fs.read_file(path).binary().to_fixedarray()
}

///|
pub async fn HostFs::write_file(
  self : HostFs,
  path : String,
  contents : Bytes,
) -> Unit {
  self.authorize_path(path, read=false, write=true)
  @fs.write_file(path, contents)
}

///|
pub async fn HostFs::create_dir(self : HostFs, path : String) -> Unit {
  self.authorize_path(path, read=false, write=true, entry=true)
  @fs.mkdir(path, recursive=true, allow_exist=true)
}

///|
pub async fn HostFs::remove_file(self : HostFs, path : String) -> Unit {
  self.authorize_path(path, read=false, write=true, entry=true)
  @fs.remove(path)
}

///|
pub async fn HostFs::read_dir(self : HostFs, path : String) -> Array[String] {
  self.authorize_path(path)
  @fs.readdir(path)
}

///|
pub async fn HostFs::is_file(self : HostFs, path : String) -> Bool {
  self.authorize_path(path)
  @fs.kind(path) is Regular
}

///|
pub async fn HostFs::is_dir(self : HostFs, path : String) -> Bool {
  self.authorize_path(path)
  @fs.kind(path) is Directory
}

///|
pub async fn HostFs::path_exists(self : HostFs, path : String) -> Bool {
  self.authorize_path(path)
  @fs.exists(path)
}

///|
pub async fn HostFs::remove_dir(self : HostFs, path : String) -> Unit {
  self.authorize_path(path, read=false, write=true, entry=true)
  let root_length = if @async.platform is Windows {
    @winpath.Path(path).root().length()
  } else if path.has_prefix("/") {
    1
  } else {
    0
  }
  let trimmed = path.trim_end(
    chars=if @async.platform is Windows { "/\\" } else { "/" },
  )
  let path = path[:@cmp.maximum(root_length, trimmed.length())]
  // remove_dir_all removes a root symlink itself, never its target.
  if @fs.kind(path, follow_symlink=false) is SymLink {
    @fs.remove(path)
  } else {
    @fs.rmdir(path, recursive=true)
  }
}
