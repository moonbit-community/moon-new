///|
/// A committed tree entry. Gitlinks retain mode 160000 and have no content;
/// template rules decide whether to ignore them or report unsupported submodules.
pub(all) struct Entry {
  path : String
  mode : String
  content : Bytes
}

///|
/// Read committed repository contents without checking out a working tree.
pub async fn load(
  source : String,
  branch? : String,
  tag? : String,
  rev? : String,
  subdir? : String = "",
) -> Array[Entry] {
  let requested = match (branch, tag, rev) {
    (None, None, None) => "HEAD"
    (Some(name), None, None)
    | (None, Some(name), None)
    | (None, None, Some(name)) => name
    _ =>
      raise @object.GitError::InvalidObject(
        "--branch, --tag and --rev are mutually exclusive",
      )
  }
  let components = if subdir.is_empty() || subdir == "." {
    []
  } else {
    subdir.split("/").map(part => part.to_owned()).to_array()
  }
  for part in components {
    @repo.verify_tree_entry_name(part)
    guard !part.contains("\\") && !part.contains(":") else {
      raise @object.GitError::InvalidObject(
        "Invalid template subdirectory: \{subdir}",
      )
    }
  }
  let refname = match (branch, tag) {
    (Some(name), _) => Some("refs/heads/" + name)
    (_, Some(name)) => Some("refs/tags/" + name)
    _ => None
  }
  if refname is Some(name) {
    guard valid_ref(name) else {
      raise @object.GitError::InvalidObject("Invalid Git reference: \{name}")
    }
  }
  let revision = rev.map(@object.ObjectId::from_hex)
  if remote_url(source) is Some(remote) {
    let (refs, _, _, symrefs) = @protocol.discover_upload_refs_with_http(
      remote, true, http_get, http_post,
    )
    let mut selected = revision
    if refname is Some(name) {
      for (id, advertised) in refs {
        if advertised == name {
          selected = Some(id)
          break
        }
      }
    } else if selected is None {
      selected = @protocol.select_default_ref(refs, symrefs).map(pair => pair.1)
    }
    guard selected is Some(id) else {
      raise @object.GitError::InvalidObject(
        "Remote Git revision not found: \{requested}",
      )
    }
    let store = @repo.ObjectStore::from_pack(
      @protocol.fetch_objects_with_http(
        remote,
        [id],
        true,
        1,
        NoFilter,
        http_get,
        http_post,
      ),
    )
    return read_commit(id, components, id => {
      guard store.get(id) is Some(object) else {
        raise @object.GitError::InvalidObject("Missing Git object: \{id}")
      }
      object
    })
  }
  let disk = Disk::{ }
  guard git_directory(disk, source) is Some((git_dir, _)) else {
    raise @object.GitError::IoError("Not a Git repository: \{source}")
  }
  let selected = match (refname, revision) {
    (Some(name), _) => @git.resolve_ref(disk, git_dir, name)
    (None, Some(id)) => Some(id)
    (None, None) => @git.resolve_head_commit(disk, git_dir)
  }
  guard selected is Some(id) else {
    raise @object.GitError::InvalidObject(
      "Git revision not found in \{source}: \{requested}",
    )
  }
  let db = @git.ObjectDb::load_lazy(disk, git_dir)
  db.disable_commit_graph()
  read_commit(id, components, id => {
    guard db.get(disk, id) is Some(object) else {
      raise @object.GitError::InvalidObject("Missing Git object: \{id}")
    }
    object
  })
}

///|
fn read_commit(
  id : @object.ObjectId,
  components : Array[String],
  get : (@object.ObjectId) -> @object.PackObject raise,
) -> Array[Entry] raise {
  let mut commit = get(id)
  let seen : Set[@object.ObjectId] = Set([])
  while commit.obj_type is Tag {
    guard !seen.contains(commit.id) else {
      raise @object.GitError::InvalidObject("Cyclic annotated tag: \{id}")
    }
    seen.add(commit.id)
    guard @git.parse_tag_object(@utf8.decode(commit.data)) is Some(target) else {
      raise @object.GitError::InvalidObject(
        "Invalid annotated tag: \{commit.id}",
      )
    }
    commit = get(target)
  }
  guard commit.obj_type is Commit else {
    raise @object.GitError::InvalidObject("Expected a commit: \{id}")
  }
  let mut tree_id = @repo.parse_commit(commit.data).tree
  for component in components {
    let tree = get(tree_id)
    guard tree.obj_type is Tree else {
      raise @object.GitError::InvalidObject("Expected a tree: \{tree_id}")
    }
    let mut found = None
    for entry in @repo.parse_tree(tree.data) {
      if entry.name == component {
        found = Some(entry)
        break
      }
    }
    guard found is Some(entry) && @repo.is_tree_mode(entry.mode) else {
      raise @object.GitError::InvalidObject(
        "Template subdirectory not found: \{components.join("/")}",
      )
    }
    tree_id = entry.id
  }
  let entries = []
  read_tree(tree_id, "", get, entries)
  entries
}

///|
fn read_tree(
  id : @object.ObjectId,
  prefix : String,
  get : (@object.ObjectId) -> @object.PackObject raise,
  entries : Array[Entry],
) -> Unit raise {
  let tree = get(id)
  guard tree.obj_type is Tree else {
    raise @object.GitError::InvalidObject("Expected a tree: \{id}")
  }
  for entry in @repo.parse_tree(tree.data) {
    @repo.verify_tree_entry_name(entry.name)
    let path = prefix + entry.name
    if @repo.is_tree_mode(entry.mode) {
      read_tree(entry.id, path + "/", get, entries)
    } else if @repo.is_gitlink_mode(entry.mode) {
      entries.push({ path, mode: entry.mode, content: b"", })
    } else {
      guard entry.mode == "100644" ||
        entry.mode == "100755" ||
        entry.mode == "120000" else {
        raise @object.GitError::InvalidObject(
          "Unsupported Git mode \{entry.mode}: \{path}",
        )
      }
      let blob = get(entry.id)
      guard blob.obj_type is Blob else {
        raise @object.GitError::InvalidObject("Expected a blob: \{path}")
      }
      entries.push({ path, mode: entry.mode, content: blob.data, })
    }
  }
}
