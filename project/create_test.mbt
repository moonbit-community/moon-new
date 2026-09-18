///|
async test "create an absent destination and preserve the default project contents" {
  let parent = @fs.tmpdir(prefix="moon-new-test-")
  defer @fs.rmdir(parent, recursive=true)
  let destination = parent + "/hello"
  let result = @project.create(destination, user="tester")
  assert_eq(result.username, "tester")
  assert_eq(result.name, "hello")
  assert_eq(
    @fs.read_file(destination + "/README.mbt.md").text(),
    "# tester/hello",
  )
  assert_eq(
    @fs.read_file(destination + "/cmd/main/main.mbt")
    .text()
    .contains("println(\"Hello\")"),
    true,
  )
  assert_true(@fs.exists(destination + "/hello_test.mbt"))
}

///|
async test "invalid names fail before creating directories" {
  let parent = @fs.tmpdir(prefix="moon-new-invalid-")
  defer @fs.rmdir(parent, recursive=true)
  let destination = parent + "/output"
  let error = try {
    ignore(@project.create(destination, user="bad/user"))
    None
  } catch {
    error => Some(error.to_string())
  }
  assert_true(error is Some(_))
  assert_false(@fs.exists(destination))
}
