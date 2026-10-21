///|
pub fn HostFs::read_file_to_string(
  self : HostFs,
  path : String,
) -> String raise {
  self.authorize_path(path)
  @utf8.decode(@sys.read_file(path))
}

///|
pub fn HostFs::read_file_to_bytes(
  self : HostFs,
  path : String,
) -> FixedArray[Byte] raise {
  self.authorize_path(path)
  @sys.read_file(path).to_fixedarray()
}

///|
pub fn HostFs::write_file(
  self : HostFs,
  path : String,
  contents : Bytes,
) -> Unit raise {
  self.authorize_path(path, read=false, write=true)
  @sys.write_file(path, contents)
}

///|
pub fn HostFs::create_dir(self : HostFs, path : String) -> Unit raise {
  self.authorize_path(path, read=false, write=true, entry=true)
  @sys.mkdir(path, recursive=true, allow_exist=true)
}

///|
pub fn HostFs::remove_file(self : HostFs, path : String) -> Unit raise {
  self.authorize_path(path, read=false, write=true, entry=true)
  @sys.remove(path)
}

///|
pub fn HostFs::read_dir(self : HostFs, path : String) -> Array[String] raise {
  self.authorize_path(path)
  @sys.readdir(path)
}

///|
pub fn HostFs::is_file(self : HostFs, path : String) -> Bool raise {
  self.authorize_path(path)
  @sys.kind(path) is Regular
}

///|
pub fn HostFs::is_dir(self : HostFs, path : String) -> Bool raise {
  self.authorize_path(path)
  @sys.kind(path) is Directory
}

///|
pub fn HostFs::path_exists(self : HostFs, path : String) -> Bool raise {
  self.authorize_path(path)
  @sys.exists(path)
}

///|
pub fn HostFs::remove_dir(self : HostFs, path : String) -> Unit raise {
  self.authorize_path(path, read=false, write=true, entry=true)
  let root_length = if @sys.platform is Windows {
    @winpath.Path(path).root().length()
  } else if path.has_prefix("/") {
    1
  } else {
    0
  }
  let trimmed = path.trim_end(
    chars=if @sys.platform is Windows { "/\\" } else { "/" },
  )
  let path = path[:@cmp.maximum(root_length, trimmed.length())].to_owned()
  // remove_dir_all removes a root symlink itself, never its target.
  if @sys.kind(path, follow_symlink=false) is SymLink {
    @sys.remove(path)
  } else {
    @sys.rmdir(path, recursive=true)
  }
}
