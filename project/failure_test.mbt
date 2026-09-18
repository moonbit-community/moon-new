///|
suberror InjectedFailure {
  InjectedFailure(String)
}

///|
async test "partial writes restore an absent destination and newly created ancestors" {
  let parent = @fs.tmpdir(prefix="moon-new-rollback-")
  defer @fs.rmdir(parent, recursive=true)
  let real = @project.FileSystem::real()
  let broken : @project.FileSystem = {
    ..real,
    create: async fn(path) {
      let output = (real.create)(path)
      if path.has_suffix("main.mbt") {
        {
          ..output,
          write: async fn(_) {
            (output.write)("partial data")
            raise InjectedFailure("write interrupted")
          },
        }
      } else {
        output
      }
    },
  }
  let failure = try {
    ignore(
      @project.create(
        parent + "/new/ancestors/project",
        user="tester",
        filesystem=broken,
      ),
    )
    None
  } catch {
    error => Some(error.to_string())
  }
  assert_true(failure is Some(text) && text.contains("write interrupted"))
  assert_eq(@fs.readdir(parent, include_hidden=true), [])
}

///|
async test "partial writes retain an originally empty destination" {
  let destination = @fs.tmpdir(prefix="moon-new-empty-")
  defer @fs.rmdir(destination, recursive=true)
  let real = @project.FileSystem::real()
  let broken : @project.FileSystem = {
    ..real,
    create: async fn(path) {
      let output = (real.create)(path)
      {
        ..output,
        write: async fn(_) {
          (output.write)("partial data")
          raise InjectedFailure("disk full")
        },
      }
    },
  }
  let failure = try {
    ignore(@project.create(destination, user="tester", filesystem=broken))
    None
  } catch {
    error => Some(error.to_string())
  }
  assert_true(failure is Some(_))
  assert_true(@fs.kind(destination) is Directory)
  assert_eq(@fs.readdir(destination, include_hidden=true), [])
}

///|
async test "README symlink failure creates an identical ordinary copy with a warning" {
  let parent = @fs.tmpdir(prefix="moon-new-copy-")
  defer @fs.rmdir(parent, recursive=true)
  let filesystem : @project.FileSystem = {
    ..@project.FileSystem::real(),
    symlink: (_, _) => raise InjectedFailure("links unavailable"),
  }
  let destination = parent + "/hello"
  let result = @project.create(destination, user="tester", filesystem~)
  assert_true(
    @fs.kind(destination + "/README.md", follow_symlink=false) is Regular,
  )
  assert_eq(
    @fs.read_file(destination + "/README.md").text(),
    @fs.read_file(destination + "/README.mbt.md").text(),
  )
  assert_true(result.warnings.any(text => text.contains("copying instead")))
}

///|
async test "README fallback copy failure rolls back the entire destination" {
  let parent = @fs.tmpdir(prefix="moon-new-copy-fail-")
  defer @fs.rmdir(parent, recursive=true)
  let real = @project.FileSystem::real()
  let filesystem : @project.FileSystem = {
    ..real,
    symlink: (_, _) => raise InjectedFailure("links unavailable"),
    create: async fn(path) {
      if path.has_suffix("README.md") && !path.contains(".githooks") {
        raise InjectedFailure("copy unavailable")
      }
      (real.create)(path)
    },
  }
  let failure = try {
    ignore(@project.create(parent + "/hello", user="tester", filesystem~))
    None
  } catch {
    error => Some(error.to_string())
  }
  assert_true(failure is Some(text) && text.contains("copy unavailable"))
  assert_eq(@fs.readdir(parent, include_hidden=true), [])
}

///|
async test "cleanup failure reports residual paths without claiming restoration" {
  let parent = @fs.tmpdir(prefix="moon-new-cleanup-fail-")
  defer @fs.rmdir(parent, recursive=true)
  let real = @project.FileSystem::real()
  let filesystem : @project.FileSystem = {
    ..real,
    create: async fn(path) {
      let output = (real.create)(path)
      { ..output, write: _ => raise InjectedFailure("write failed"), }
    },
    remove: _ => raise InjectedFailure("remove failed"),
  }
  let failure = try {
    ignore(@project.create(parent + "/hello", user="tester", filesystem~))
    None
  } catch {
    error => Some(error.to_string())
  }
  assert_true(
    failure is Some(text) &&
    text.contains("Cleanup failed") &&
    text.contains("moon.pkg"),
  )
  assert_true(@fs.exists(parent + "/hello/moon.pkg"))
}

///|
impl Show for InjectedFailure with fn output(self, logger) {
  let InjectedFailure(message) = self
  logger.write_string(message)
}

///|
async test "a file appearing after preflight is never overwritten or removed" {
  let parent = @fs.tmpdir(prefix="moon-new-race-")
  defer @fs.rmdir(parent, recursive=true)
  let real = @project.FileSystem::real()
  let filesystem : @project.FileSystem = {
    ..real,
    create: async fn(path) {
      if path.has_suffix("main.mbt") {
        @fs.write_file(path, "owned by another writer", create_mode=CreateNew)
      }
      (real.create)(path)
    },
  }
  let failure = try {
    ignore(@project.create(parent + "/hello", user="tester", filesystem~))
    None
  } catch {
    error => Some(error.to_string())
  }
  assert_true(failure is Some(text) && text.contains("Cleanup failed"))
  assert_eq(
    @fs.read_file(parent + "/hello/cmd/main/main.mbt").text(),
    "owned by another writer",
  )
  assert_false(@fs.exists(parent + "/hello/moon.pkg"))
}

///|
async test "Unix executable permission failure is a warning after successful generation" {
  if @async.platform is Windows {
    return
  }
  let parent = @fs.tmpdir(prefix="moon-new-mode-")
  defer @fs.rmdir(parent, recursive=true)
  let filesystem : @project.FileSystem = {
    ..@project.FileSystem::real(),
    chmod: (_, _) => raise InjectedFailure("mode unavailable"),
  }
  let result = @project.create(parent + "/hello", user="tester", filesystem~)
  assert_true(result.warnings.any(text => text.contains("executable")))
  assert_true(@fs.exists(parent + "/hello/moon.mod"))
}

///|
async test "Windows bare drive paths remain drive-relative at the filesystem boundary" {
  if !(@async.platform is Windows) {
    return
  }
  // Guard the first file creation: even a regressed implementation must never
  // write to a real drive root while this path behavior is being tested.
  let filesystem : @project.FileSystem = {
    ..@project.FileSystem::real(),
    kind: _ => Some(@fs.Directory),
    entries: _ => [],
    create: path => {
      if path == "C:moon.pkg" {
        raise InjectedFailure("drive-relative location preserved")
      }
      raise InjectedFailure("incorrect output location: " + path)
    },
  }
  let failure = try {
    ignore(@project.create("C:", user="tester", name="hello", filesystem~))
    None
  } catch {
    error => Some(error.to_string())
  }
  assert_true(
    failure is Some(text) && text.contains("drive-relative location preserved"),
  )
}
