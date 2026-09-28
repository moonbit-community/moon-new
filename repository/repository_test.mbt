///|
async test "unsupported transports and authenticated URLs fail before network access" {
  for
    source in [
      "ssh://git@example.com/repo", "git@example.com:repo", "http://example.com/repo",
      "https://user:secret@example.com/repo", "https:///repo", "file:///tmp/repo",
    ] {
    try @repository.load(source) catch {
      error =>
        assert_true(error.to_string().contains("source"), msg=error.to_string())
    } noraise {
      _ => fail("Expected source rejection: \{source}")
    }
  }
}

///|
async test "repository reads its committed root on both supported targets" {
  let entries = @repository.load(".")
  assert_true(entries.any(entry => entry.path == "moon.mod"))
  assert_false(entries.any(entry => entry.path.has_prefix(".git/")))
}

///|
async test "anonymous HTTPS smoke test" {
  if @env.get_env_var("MOON_NEW_TEST_REMOTE") != Some("1") {
    println("SKIP network smoke test; set MOON_NEW_TEST_REMOTE=1 to enable")
    return
  }
  let entries = @repository.load(
    "https://github.com/octocat/Hello-World.git",
    branch="master",
  )
  assert_true(
    entries.any(entry => {
      entry.path == "README" && entry.content == b"Hello World!\n"
    }),
  )
  let shorthand = @repository.load("octocat/Hello-World")
  assert_true(
    shorthand.any(entry => {
      entry.path == "README" && entry.content == b"Hello World!\n"
    }),
  )
}
