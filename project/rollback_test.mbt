///|
async test "a real file creation failure removes output and newly created ancestors" {
  let parent = @fs.tmpdir(prefix="moon-new-rollback-")
  defer @fs.rmdir(parent, recursive=true)
  // The name passes validation but exceeds the host's filename component limit.
  // Earlier template entries have already created files and directories.
  let failure = try {
    ignore(
      @project.create(
        parent + "/new/ancestors/project",
        user="tester",
        name="a".repeat(1024),
      ),
    )
    None
  } catch {
    error => Some(error.to_string())
  }
  assert_true(failure is Some(text) && text.contains("Could not create"))
  assert_eq(@fs.readdir(parent, include_hidden=true), [])
}

///|
async test "a real file creation failure retains an originally empty destination" {
  let destination = @fs.tmpdir(prefix="moon-new-empty-")
  defer @fs.rmdir(destination, recursive=true)
  let failure = try {
    ignore(@project.create(destination, user="tester", name="a".repeat(1024)))
    None
  } catch {
    error => Some(error.to_string())
  }
  assert_true(failure is Some(text) && text.contains("Could not create"))
  assert_true(@fs.kind(destination) is Directory)
  assert_eq(@fs.readdir(destination, include_hidden=true), [])
}
