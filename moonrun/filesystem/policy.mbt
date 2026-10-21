///|
pub fn HostFs::authorize_path(
  self : HostFs,
  path : String,
  read~ : Bool = true,
  write~ : Bool = false,
  entry~ : Bool = false,
) -> Unit raise {
  if self.policy is Some(policy) {
    let canonical = @policy.policy_path(path, entry)
    if !(canonical is Some(path) && policy.allows_path(path, read~, write~)) {
      self.stdio.deny(
        if read && write {
          "file access"
        } else if write {
          "file write"
        } else {
          "file read"
        },
        target=path,
      )
    }
  }
}

///|
pub fn HostFs::authorize_at(
  self : HostFs,
  path : String,
  parent : @resource.Resource?,
  follow : Bool,
) -> Unit raise {
  if self.policy is None {
    return
  }
  let path = if @path.Path(path).is_absolute() || parent is None {
    self.resolve(path)
  } else {
    guard parent is Some(parent) && parent.path is Some(directory) else {
      self.stdio.deny("file read", target="<untracked resource>")
      return
    }
    @working_directory.resolve_from(directory, path)
  }
  self.authorize_path(path, entry=!follow)
}

///|
pub fn HostFs::authorize_resource(
  self : HostFs,
  fd : @resource.Resource,
  write : Bool,
) -> Unit raise {
  if self.policy is None {
    return
  }
  guard fd.path is Some(path) else {
    self.stdio.deny(
      if write {
        "file write"
      } else {
        "file read"
      },
      target="<untracked resource>",
    )
    return
  }
  self.authorize_path(path, read=!write, write~)
}
