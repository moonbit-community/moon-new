///|
async test "CLI matches the independent official fixture" {
  let s = Sandbox::new()
  defer s.cleanup()
  let fixture = @json.parse(
    @fs.read_file(root() + "/tests/fixtures/official.json").text(),
  )
  guard fixture is { "files": Object(expected), "links": Object(links), .. } else {
    fail("invalid fixture")
  }
  let result = s.run(["hello", "--user", "tester"])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_true(result.stdout.contains("Created tester/hello"))
  let names = expected.keys().to_array() + links.keys().to_array()
  names.sort()
  assert_eq(files(s.root + "/hello"), names)
  for path, content in expected {
    guard content is String(text) else { fail("invalid fixture content") }
    assert_eq(
      @fs.read_file(s.root + "/hello/" + path).binary(),
      @utf8.encode(text),
      msg=path,
    )
  }
  for path, target in links {
    guard target is String(target) else { fail("invalid fixture link") }
    if @fs.kind(s.root + "/hello/" + path, follow_symlink=false) is SymLink {
      assert_eq(
        @fs.realpath(s.root + "/hello/" + path),
        @fs.realpath(s.root + "/hello/" + target),
      )
      if !windows() {
        assert_eq(
          checked("readlink", [s.root + "/hello/" + path], cwd=s.root)
          .trim()
          .to_owned(),
          target,
        )
      }
    } else {
      assert_eq(s.read("hello/" + path), s.read("hello/" + target))
      assert_true(result.stderr.contains("copying"))
    }
  }
  if !windows() {
    assert_eq(permission(s.root + "/hello/.githooks/pre-commit"), "755")
  }
  assert_true(@fs.kind(s.root + "/hello/.git") is Directory)
}

///|
async test "CLI credentials and explicit user" {
  let s = Sandbox::new()
  defer s.cleanup()
  @fs.mkdir(s.env["MOON_HOME"])
  let credentials = s.env["MOON_HOME"] + "/credentials.json"
  @fs.write_file(
    credentials, "{\"token\":\"test-token\",\"username\":\"saved_user\"}",
  )
  let result = s.run(["saved"])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_eq(s.read("saved/README.mbt.md"), "# saved_user/saved")
  @fs.write_file(credentials, "not JSON")
  let result = s.run(["explicit", "--user", "chosen"])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_false(result.stderr.contains("credentials"))
  let result = s.run(["fallback", "--quiet"])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_eq(
    result.stderr,
    "Warning: Could not read or parse credentials; using default username. Log in again with moon login or pass --user.\n",
  )
  assert_eq(result.stdout, "")
  assert_eq(s.read("fallback/README.mbt.md"), "# username/fallback")
  assert_false((result.stdout + result.stderr).contains("test-token"))
}

///|
async test "CLI destinations and quiet output" {
  let s = Sandbox::new()
  defer s.cleanup()
  @fs.mkdir(s.root + "/empty")
  let result = s.run(["empty", "--user", "tester", "-q"])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_eq(result.stdout, "")
  assert_eq(result.stderr, "")
  for (name, hidden) in [("populated", ".DS_Store"), ("repository", ".git")] {
    @fs.mkdir(s.root + "/" + name)
    @fs.write_file(s.root + "/" + name + "/" + hidden, "keep me")
    let result = s.run([name, "--user", "tester"])
    assert_eq(result.status, 1)
    assert_eq(result.stderr, "Error: Destination is not empty: \{name}\n")
    assert_eq(@fs.readdir(s.root + "/" + name, include_hidden=true), [hidden])
    assert_eq(s.read(name + "/" + hidden), "keep me")
  }
  @fs.write_file(s.root + "/regular", "keep me")
  assert_eq(s.run(["regular", "--user", "tester"]).status, 1)
  assert_eq(s.read("regular"), "keep me")
}

///|
async test "CLI names and argument forms" {
  let s = Sandbox::new()
  defer s.cleanup()
  let result = s.run(["foo.bar", "--user=用户𐐀", "--quiet"])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_eq(s.read("foo.bar/README.mbt.md"), "# 用户𐐀/foo")
  let result = s.run(["override", "--name=sample_test", "--user=tester", "-q"])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_eq(
    result.stderr,
    "Warning: Project names ending in _test or _wbtest may conflict with test file conventions.\n",
  )
  assert_eq(result.stdout, "")
  assert_true(s.exists("override/sample_test.mbt"))
  for user in ["", "a/b", "emoji😀", "a\u0345"] {
    let result = s.run(["invalid", "--user", user])
    assert_eq(result.status, 1)
    assert_eq(
      result.stderr,
      "Error: Usernames can only contain Unicode alphanumeric characters, dashes (-), and underscores (_), and must not be empty.\n",
    )
    assert_false(s.exists("invalid"))
  }
  for name in ["", "0hello", "a.b", "a/b", "用户"] {
    let result = s.run(["invalid", "--name", name, "--user", "tester"])
    assert_eq(result.status, 1)
    let expected = if name.is_empty() {
      "Project name must not be empty."
    } else {
      "Invalid project name: \{name}. Expected [A-Za-z_][A-Za-z0-9_-]*."
    }
    assert_eq(result.stderr, "Error: \{expected}\n")
    assert_false(s.exists("invalid"))
  }
  let result = s.run(["--user", "tester", "--name", "named", "--", "-directory"])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_true(s.exists("-directory/named.mbt"))
}

///|
async test "CLI strict credential schema" {
  let s = Sandbox::new()
  defer s.cleanup()
  @fs.mkdir(s.env["MOON_HOME"])
  let credentials = s.env["MOON_HOME"] + "/credentials.json"
  for
    index, document in [
      "{\"username\":\"saved\"}", "{\"token\":123,\"username\":\"saved\"}", "{\"token\":\"secret\",\"username\":123}",
      "{\"token\":\"secret\",\"username\":\"saved\",}", "{/*comment*/\"token\":\"secret\",\"username\":\"saved\"}",
    ] {
    @fs.write_file(credentials, document)
    let name = "invalid_\{index}"
    let result = s.run([name, "-q"])
    assert_eq(result.status, 0, msg=result.stderr)
    let message = if index < 3 {
      "Invalid credentials fields"
    } else {
      "Could not read or parse credentials"
    }
    assert_eq(
      result.stderr,
      "Warning: \{message}; using default username. Log in again with moon login or pass --user.\n",
    )
    assert_false(result.stderr.contains("secret"))
    assert_eq(s.read(name + "/README.mbt.md"), "# username/" + name)
  }
  for
    index, document in [
      "{\"token\":\"secret\"}", "{\"token\":\"secret\",\"username\":null}",
    ] {
    @fs.write_file(credentials, document)
    let name = "absent_\{index}"
    let result = s.run([name, "-q"])
    assert_eq(result.status, 0, msg=result.stderr)
    assert_eq(result.stderr, "")
    assert_eq(s.read(name + "/README.mbt.md"), "# username/" + name)
  }
}

///|
async test "CLI home lookup and unavailable Git" {
  let s = Sandbox::new()
  defer s.cleanup()
  for key in ["MOON_HOME", "HOME", "USERPROFILE"] {
    s.env.remove(key)
  }
  let result = s.run(["fallback", "-q"])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_true(result.stderr.contains("credentials directory"))
  assert_eq(s.read("fallback/README.mbt.md"), "# username/fallback")
  s.env["PATH"] = ""
  let result = s.run(["no_git", "--user", "tester", "-q"])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_eq(result.stderr, "")
  assert_eq(result.stdout, "")
  assert_true(s.exists("no_git/moon.mod"))
  assert_eq(s.read("no_git/.git/HEAD"), "ref: refs/heads/main\n")
}

///|
async test "CLI reuses the parent Git repository" {
  let s = Sandbox::new()
  defer s.cleanup()
  ignore(checked("git", ["init", s.root], cwd=s.root))
  let result = s.run(["child", "--user", "tester", "-q"])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_eq(result.stderr, "")
  assert_false(s.exists("child/.git"))
  assert_true(s.exists(".git"))
}

///|
async test "CLI rejects destination symlinks and follows parent symlinks" {
  let s = Sandbox::new()
  defer s.cleanup()
  @fs.mkdir(s.root + "/real")
  if !directory_link(s.root + "/real", s.root + "/link") {
    return
  }
  for target in ["link", "link/"] {
    assert_eq(s.run([target, "--user", "tester"]).status, 1)
    assert_eq(@fs.readdir(s.root + "/real", include_hidden=true), [])
  }
  let result = s.run(["link/child", "--user", "tester"])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_true(s.exists("real/child/moon.mod"))
  @fs.symlink(
    target=s.root + "/missing",
    s.root + "/dangling",
    force_symlink=true,
  )
  assert_eq(s.run(["dangling", "--user", "tester"]).status, 1)
  assert_false(s.exists("missing"))
}

///|
async test "CLI permissions respect the Unix umask" {
  if windows() {
    println("SKIP Unix permissions on Windows")
    return
  }
  let s = Sandbox::new()
  defer s.cleanup()
  let (program, prefix) = cli_command()
  let result = command(
    "sh",
    ["-c", "umask 002; exec \"$@\"", "moon-new-test", program] +
    prefix +
    ["permissions", "--user", "tester"],
    cwd=s.root,
    env=s.env,
  )
  assert_eq(result.status, 0, msg=result.stderr)
  assert_eq(permission(s.root + "/permissions"), "775")
  assert_eq(permission(s.root + "/permissions/moon.mod"), "664")
  assert_eq(permission(s.root + "/permissions/.githooks/pre-commit"), "755")
}

///|
async test "CLI library initialization is independent of Git command configuration" {
  let s = Sandbox::new()
  defer s.cleanup()
  s.env["GIT_CONFIG_COUNT"] = "1"
  s.env["GIT_CONFIG_KEY_0"] = "init.defaultBranch"
  s.env["GIT_CONFIG_VALUE_0"] = "invalid branch name"
  let result = s.run(["git_failure", "--user", "tester", "-q"])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_eq(result.stdout, "")
  assert_eq(result.stderr, "")
  assert_eq(s.read("git_failure/.git/HEAD"), "ref: refs/heads/main\n")
  assert_eq(s.read("git_failure/README.mbt.md"), "# tester/git_failure")
}

///|
async test "CLI dotdot cannot bypass destination checks" {
  let s = Sandbox::new()
  defer s.cleanup()
  @fs.mkdir(s.root + "/existing")
  @fs.write_file(s.root + "/existing/unrelated.txt", "keep me")
  let result = s.run(["missing/../existing", "--user", "tester", "-q"])
  assert_eq(result.status, 1)
  assert_true(result.stderr.contains("not empty"))
  assert_eq(@fs.readdir(s.root + "/existing", include_hidden=true), [
    "unrelated.txt",
  ])
  assert_eq(s.read("existing/unrelated.txt"), "keep me")
  assert_false(s.exists("missing"))
  @fs.mkdir(s.root + "/empty")
  if !directory_link(s.root + "/empty", s.root + "/link") {
    return
  }
  assert_eq(s.run(["missing/../link", "--user", "tester", "-q"]).status, 1)
  assert_eq(@fs.readdir(s.root + "/empty", include_hidden=true), [])
  assert_false(s.exists("missing"))
}

///|
async test "CLI Windows drive-relative names" {
  if !windows() {
    println("SKIP Windows drive-relative paths on Unix")
    return
  }
  let s = Sandbox::new()
  defer s.cleanup()
  let result = s.run([
    s.root[:2].to_owned() + "drive_relative",
    "--user",
    "tester",
    "-q",
  ])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_eq(s.read("drive_relative/README.mbt.md"), "# tester/drive_relative")
}

///|
async test "CLI help and argument errors" {
  let s = Sandbox::new()
  defer s.cleanup()
  let result = s.run(["--help"])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_true(result.stdout.contains("--user"))
  assert_true(result.stdout.contains("--name"))
  assert_eq(result.stderr, "")
  for args in [[], ["--template", "repo"], ["hello", "--unknown"]] {
    let result = s.run(args)
    assert_eq(result.status, 2)
    assert_true(result.stderr.contains("Error:"))
    assert_eq(@fs.readdir(s.root, include_hidden=true), [])
  }
}

///|
async test "CLI retains warnings before a validation error in either quiet mode" {
  let s = Sandbox::new()
  defer s.cleanup()
  for quiet in [[], ["--quiet"]] {
    let result = s.run(["invalid", "--name", "0bad"] + quiet)
    assert_eq(result.status, 1)
    assert_eq(result.stdout, "")
    assert_eq(
      result.stderr,
      "Warning: Using default username. Log in with moon login or pass --user.\nError: Invalid project name: 0bad. Expected [A-Za-z_][A-Za-z0-9_-]*.\n",
    )
    assert_false(s.exists("invalid"))
  }
}

///|
async test "CLI keeps all warnings in order when the destination is rejected" {
  let s = Sandbox::new()
  defer s.cleanup()
  @fs.mkdir(s.root + "/occupied")
  @fs.write_file(s.root + "/occupied/keep", "original")
  let result = s.run(["occupied", "--name", "sample_test", "-q"])
  assert_eq(result.status, 1)
  assert_eq(result.stdout, "")
  assert_eq(
    result.stderr,
    "Warning: Using default username. Log in with moon login or pass --user.\nWarning: Project names ending in _test or _wbtest may conflict with test file conventions.\nError: Destination is not empty: occupied\n",
  )
  assert_eq(s.read("occupied/keep"), "original")
  assert_eq(@fs.readdir(s.root + "/occupied", include_hidden=true), ["keep"])
}

///|
async test "CLI credential diagnostics explain recovery without exposing credentials" {
  let s = Sandbox::new()
  defer s.cleanup()
  @fs.mkdir(s.env["MOON_HOME"])
  let credentials = s.env["MOON_HOME"] + "/credentials.json"
  for
    (document, message) in [
      (
        "{\"token\":\"do-not-print-token\",", "Could not read or parse credentials",
      ),
      (
        "{\"token\":\"do-not-print-token\",\"username\":123}", "Invalid credentials fields",
      ),
      ("{\"username\":\"do-not-print-token\"}", "Invalid credentials fields"),
    ] {
    @fs.write_file(credentials, document)
    let result = s.run(["invalid", "--name", "", "-q"])
    assert_eq(result.status, 1)
    assert_eq(result.stdout, "")
    assert_eq(
      result.stderr,
      "Warning: \{message}; using default username. Log in again with moon login or pass --user.\nError: Project name must not be empty.\n",
    )
    assert_false(result.stderr.contains("do-not-print-token"))
    assert_false(s.exists("invalid"))
    let explicit = s.run(["invalid", "--user", "tester", "--name", ""])
    assert_eq(explicit.status, 1)
    assert_eq(explicit.stderr, "Error: Project name must not be empty.\n")
  }
}

///|
async test "CLI filesystem errors retain warnings, project context, and their cause" {
  let s = Sandbox::new()
  defer s.cleanup()
  let name = "a".repeat(1024)
  for quiet in [[], ["-q"]] {
    let result = s.run(["broken", "--name", name] + quiet)
    assert_eq(result.status, 1)
    assert_eq(result.stdout, "")
    // The OS cause is platform-dependent; our prefix and ordering are stable.
    assert_true(
      result.stderr.has_prefix(
        "Warning: Using default username. Log in with moon login or pass --user.\nError: Could not create project at broken.\nCaused by: ",
      ),
    )
    assert_true(result.stderr.contains(name + ".mbt"))
    assert_false(s.exists("broken"))
  }
}
