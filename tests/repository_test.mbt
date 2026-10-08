///|
async test "repository reads committed bytes and modes without a checkout" {
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  ignore(checked("git", ["init", "-b", "main", "source"], cwd=s.root))
  let source = s.root + "/source"
  @fs.write_file(source + "/file.txt", "committed")
  @fs.write_file(source + "/binary", b"\x00\xff")
  ignore(checked("git", ["add", "."], cwd=source))
  ignore(checked("git", ["update-index", "--chmod=+x", "file.txt"], cwd=source))
  ignore(
    checked(
      "git",
      [
        "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m",
        "fixture",
      ],
      cwd=source,
    ),
  )
  @fs.write_file(source + "/file.txt", "uncommitted")
  @fs.write_file(source + "/untracked", "untracked")
  let entries = @repository.load(source)
  assert_eq(entries.length(), 2)
  assert_true(
    entries.any(entry => {
      entry.path == "file.txt" &&
      entry.mode == "100755" &&
      entry.content == b"committed"
    }),
  )
  assert_true(
    entries.any(entry => entry.path == "binary" && entry.content == b"\x00\xff"),
  )
}

///|
async test "repository supports bare repositories and linked worktrees" {
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  ignore(checked("git", ["init", "-b", "main", "source"], cwd=s.root))
  let source = s.root + "/source"
  @fs.write_file(source + "/file", "committed")
  ignore(checked("git", ["add", "."], cwd=source))
  ignore(
    checked(
      "git",
      [
        "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m",
        "fixture",
      ],
      cwd=source,
    ),
  )
  ignore(checked("git", ["clone", "--bare", "source", "bare"], cwd=s.root))
  assert_eq(@repository.load(s.root + "/bare")[0].content, b"committed")
  ignore(
    checked(
      "git",
      ["worktree", "add", "--detach", s.root + "/linked"],
      cwd=source,
    ),
  )
  assert_eq(@repository.load(s.root + "/linked")[0].content, b"committed")
  @fs.mkdir(s.root + "/linked/child")
  assert_false(@repository.initialize(s.root + "/linked/child"))
  assert_false(@fs.exists(s.root + "/linked/child/.git"))
}

///|
async test "repository initialization reports filesystem failure without removing project files" {
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  @fs.write_file(s.root + "/.git", "occupied")
  @fs.write_file(s.root + "/project-file", "keep")
  try @repository.initialize(s.root) catch {
    error =>
      assert_true(error.to_string().contains(".git"), msg=error.to_string())
  } noraise {
    _ => fail("Expected occupied Git metadata to fail")
  }
  assert_eq(s.read(".git"), "occupied")
  assert_eq(s.read("project-file"), "keep")
}

///|
async test "template matching uses source paths, nearest matches and root-local configuration" {
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  ignore(checked("git", ["init", "-b", "main", "source"], cwd=s.root))
  let source = s.root + "/source"
  @fs.write_file(source + "/moon.new.json", "{\"include\":[]}")
  let cases : Array[(String, String, Array[String])] = [
    (
      "default",
      "{}",
      ["root.txt", "sub/root.txt", "sub/deep/item", "{{module}}.txt"],
    ),
    ("empty", "{\"include\":[]}", []),
    ("anchored", "{\"include\":[\"/root.txt\"]}", ["root.txt"]),
    ("parent", "{\"include\":[\"/sub/deep\"]}", ["sub/deep/item"]),
    (
      "negation",
      "{\"include\":[\"!sub/\",\"*.txt\"]}",
      ["root.txt", "sub/root.txt", "{{module}}.txt"],
    ),
    (
      "nearest",
      "{\"include\":[\"*.txt\",\"!sub/\"]}",
      ["root.txt", "sub/root.txt", "{{module}}.txt"],
    ),
    (
      "exclude",
      "{\"exclude\":[\"*.txt\",\"!root.txt\"]}",
      ["root.txt", "sub/root.txt", "sub/deep/item"],
    ),
    (
      "variables",
      "{\"include\":[\"\\\\{\\\\{module\\\\}\\\\}.txt\"]}",
      ["{{module}}.txt"],
    ),
  ]
  for (name, config, _) in cases {
    @fs.mkdir(source + "/" + name + "/sub/deep", recursive=true)
    @fs.write_file(source + "/" + name + "/moon.new.json", config)
    for file in ["root.txt", "sub/root.txt", "sub/deep/item", "{{module}}.txt"] {
      @fs.write_file(source + "/" + name + "/" + file, "{{module}}")
    }
  }
  @fs.mkdir(source + "/no_config")
  @fs.write_file(source + "/no_config/file", "{{module}}")
  ignore(checked("git", ["add", "."], cwd=source))
  ignore(
    checked(
      "git",
      [
        "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m",
        "rules",
      ],
      cwd=source,
    ),
  )
  for (name, _, expected) in cases {
    let output = @template.render_repository(
      @repository.load(source, subdir=name),
      "tester",
      "hello",
    )
    assert_eq(output.length(), 4, msg=name)
    let rendered = []
    for entry in output {
      guard entry is File(path~, content~, ..) else {
        fail("Expected an ordinary file")
      }
      if content == b"hello" {
        rendered.push(path)
      } else {
        assert_eq(content, b"{{module}}", msg=path)
      }
    }
    let expected = expected.map(path => {
      path.replace(old="{{module}}", new="hello")
    })
    rendered.sort()
    expected.sort()
    assert_eq(rendered, expected, msg=name)
  }
  assert_true(
    @template.render_repository(
      @repository.load(source, subdir="no_config"),
      "tester",
      "hello",
    )[0]
    is File(content=b"hello", ..),
  )
}

///|
async test "template validation rejects malformed config, binary rendering, submodules and LFS" {
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  ignore(checked("git", ["init", "-b", "main", "source"], cwd=s.root))
  let source = s.root + "/source"
  @fs.write_file(source + "/file", "fixture")
  ignore(checked("git", ["add", "."], cwd=source))
  let identity = ["-c", "user.name=Test", "-c", "user.email=test@example.com"]
  ignore(checked("git", identity + ["commit", "-m", "base"], cwd=source))
  let commit = checked("git", ["rev-parse", "HEAD"], cwd=source)
    .trim()
    .to_owned()
  let invalid : Array[(String, String, String)] = [
    ("unknown", "{\"extra\":[]}", "extra"),
    ("type", "{\"include\":null}", "include"),
    ("member", "{\"ignore\":[3]}", "ignore"),
    ("object", "[]", "object"),
    ("json", "{", "moon.new.json"),
    ("escape", "{\"ignore\":[\"../file\"]}", "ignore"),
    ("binary", "{}", "binary"),
    ("submodule", "{}", "vendor"),
    ("lfs", "{\"include\":[]}", "large"),
  ]
  for (name, config, _) in invalid {
    @fs.mkdir(source + "/" + name)
    @fs.write_file(source + "/" + name + "/moon.new.json", config)
  }
  @fs.write_file(source + "/binary/binary", b"\xff")
  let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:" +
    "a".repeat(64) +
    "\nsize 123\n"
  @fs.write_file(source + "/lfs/large", pointer)
  @fs.mkdir(source + "/ignored")
  @fs.write_file(
    source + "/ignored/moon.new.json",
    "{\"ignore\":[\"vendor\",\"large\",\"binary\"]}",
  )
  @fs.write_file(source + "/ignored/large", pointer)
  @fs.write_file(source + "/ignored/binary", b"\xff")
  ignore(checked("git", ["add", "."], cwd=source))
  for path in ["submodule/vendor", "ignored/vendor"] {
    ignore(
      checked(
        "git",
        [
          "update-index",
          "--add",
          "--cacheinfo",
          "160000," + commit + "," + path,
        ],
        cwd=source,
      ),
    )
  }
  ignore(
    checked("git", identity + ["commit", "-m", "invalid templates"], cwd=source),
  )
  for (name, _, message) in invalid {
    let entries = @repository.load(source, subdir=name)
    try @template.render_repository(entries, "tester", "hello") catch {
      error =>
        assert_true(error.to_string().contains(message), msg=error.to_string())
    } noraise {
      _ => fail("Expected template validation error: \{name}")
    }
  }
  assert_eq(
    @template.render_repository(
      @repository.load(source, subdir="ignored"),
      "tester",
      "hello",
    ).length(),
    0,
  )
}

///|
async test "template rules distinguish byte copies, literal omissions and content rendering" {
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  ignore(checked("git", ["init", "-b", "main", "source"], cwd=s.root))
  let source = s.root + "/source"
  @fs.mkdir(source + "/src")
  for name in ["keep.txt", "raw.txt", "omit.txt", "[x].txt", "x.txt"] {
    @fs.write_file(source + "/src/" + name, "{{module}}")
  }
  @fs.write_file(source + "/binary", b"\x00\xff")
  let config =
    #|{"include":["src/", "!src/raw.txt"],"exclude":["**"],"ignore":["src/[x].txt","missing"]}
  @fs.write_file(source + "/moon.new.json", config)
  ignore(checked("git", ["add", "."], cwd=source))
  ignore(
    checked(
      "git",
      [
        "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m",
        "fixture",
      ],
      cwd=source,
    ),
  )
  let warnings = []
  let entries = @repository.load(source)
  let output = @template.render_repository(
    entries,
    "tester",
    "hello",
    warnings~,
  )
  assert_eq(output.length(), 5)
  for
    (expected_path, expected_content) in [
      ("src/keep.txt", b"hello"),
      ("src/omit.txt", b"hello"),
      ("src/x.txt", b"hello"),
      ("src/raw.txt", b"{{module}}"),
      ("binary", b"\x00\xff"),
    ] {
    assert_true(
      output.any(entry => {
        entry is File(path~, content~, ..) &&
        path == expected_path &&
        content == expected_content
      }),
      msg=expected_path,
    )
  }
  assert_eq(warnings.length(), 1)
  assert_true(warnings[0].contains("exclude"))
}

///|
async test "repository selects packed refs, annotated tags, commits and subdirectories" {
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  ignore(checked("git", ["init", "-b", "main", "source"], cwd=s.root))
  let source = s.root + "/source"
  @fs.mkdir(source + "/nested")
  @fs.write_file(source + "/nested/file", "first")
  ignore(checked("git", ["add", "."], cwd=source))
  let identity = ["-c", "user.name=Test", "-c", "user.email=test@example.com"]
  ignore(checked("git", identity + ["commit", "-m", "first"], cwd=source))
  let first = checked("git", ["rev-parse", "HEAD"], cwd=source)
    .trim()
    .to_owned()
  ignore(
    checked("git", identity + ["tag", "-a", "v1", "-m", "first"], cwd=source),
  )
  @fs.write_file(source + "/nested/file", "second")
  ignore(checked("git", identity + ["commit", "-am", "second"], cwd=source))
  ignore(checked("git", ["gc", "--prune=now"], cwd=source))
  let tagged = @repository.load(source, tag="v1", subdir="nested")
  assert_eq(tagged.length(), 1)
  assert_eq(tagged[0].path, "file")
  assert_eq(tagged[0].content, b"first")
  assert_eq(@repository.load(source, rev=first)[0].content, b"first")
  assert_eq(@repository.load(source, branch="main")[0].content, b"second")
  for
    subdir in [
      "missing", "nested/file", "../source", "/nested", "nested/../nested",
    ] {
    try @repository.load(source, subdir~) catch {
      _ => ()
    } noraise {
      _ => fail("Expected an invalid subdirectory: \{subdir}")
    }
  }
  try @repository.load(source, branch="main", tag="v1") catch {
    _ => ()
  } noraise {
    _ => fail("Expected conflicting selectors to fail")
  }
  try @repository.load(source, branch="missing") catch {
    _ => ()
  } noraise {
    _ => fail("Expected a missing branch to fail")
  }
}
