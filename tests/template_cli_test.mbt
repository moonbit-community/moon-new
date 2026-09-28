///|
async fn commit_template(source : String) -> Unit {
  ignore(checked("git", ["add", "."], cwd=source))
  ignore(
    checked(
      "git",
      [
        "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m",
        "template",
      ],
      cwd=source,
    ),
  )
}

///|
async test "CLI generates a committed template with rendered paths and byte copies without Git on PATH" {
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  ignore(checked("git", ["init", "-b", "main", "source"], cwd=s.root))
  let source = s.root + "/source"
  @fs.mkdir(source + "/{{module}}")
  @fs.write_file(
    source + "/moon.new.json",
    "{\"exclude\":[\"*.bin\",\"raw.txt\"]}",
  )
  @fs.write_file(source + "/{{module}}/name.txt", "{{username}}/{{module}}")
  @fs.write_file(source + "/{{module}}/data.bin", b"\x00\xff")
  @fs.write_file(source + "/raw.txt", "{{unknown}}")
  @fs.write_file(source + "/script", "#!/bin/sh\necho {{module}}\n")
  ignore(checked("git", ["add", "."], cwd=source))
  ignore(checked("git", ["update-index", "--chmod=+x", "script"], cwd=source))
  ignore(
    checked(
      "git",
      [
        "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m",
        "template",
      ],
      cwd=source,
    ),
  )
  @fs.write_file(source + "/{{module}}/name.txt", "dirty")
  @fs.write_file(source + "/untracked", "omit")
  s.env["PATH"] = ""
  let result = s.run([
    "out", "--template", "./source", "--user", "alice", "--name", "demo", "-q",
  ])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_eq(result.stdout, "")
  assert_eq(result.stderr, "")
  assert_eq(s.read("out/demo/name.txt"), "alice/demo")
  assert_eq(@fs.read_file(s.root + "/out/demo/data.bin").binary(), b"\x00\xff")
  assert_eq(s.read("out/raw.txt"), "{{unknown}}")
  assert_eq(s.read("out/script"), "#!/bin/sh\necho demo\n")
  assert_false(s.exists("out/moon.new.json"))
  assert_false(s.exists("out/untracked"))
  assert_eq(s.read("out/.git/HEAD"), "ref: refs/heads/main\n")
  assert_false(s.exists("out/.git/refs/heads/main"))
  if !windows() {
    assert_eq(permission(s.root + "/out/script"), "755")
  }
}

///|
async test "template failures report source paths and leave destinations untouched" {
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  ignore(checked("git", ["init", "-b", "main", "source"], cwd=s.root))
  let source = s.root + "/source"
  let cases : Array[(String, Array[(String, String)], String)] = [
    ("unknown", [("file.txt", "{{missing}}")], "missing"),
    ("package", [("file.txt", "{{package}}")], "package"),
    ("syntax", [("file.txt", "{% if %}")], "file.txt"),
    ("collision", [("{{module}}.txt", "one"), ("demo.txt", "two")], "collision"),
    ("ancestor", [("{{module}}", "one"), ("demo/file", "two")], "collision"),
    ("escape", [("{{ '..' }}/escaped", "one")], "path"),
    ("absolute", [("{{ '' }}/escaped", "one")], "path"),
    ("metadata", [("{{ '.git' }}/config", "one")], "path"),
    ("binary", [("file.txt", "text")], "file.txt"),
  ]
  for (name, files, _) in cases {
    for (file, content) in files {
      let full = source + "/" + name + "/" + file
      let parent = @path.Path(full).dirname().to_string()
      if !@fs.exists(parent) {
        @fs.mkdir(parent, recursive=true)
      }
      @fs.write_file(full, content)
    }
  }
  @fs.write_file(source + "/binary/file.txt", b"\xff")
  commit_template(source)
  for (name, _, message) in cases {
    let destination = "out-" + name
    let result = s.run([
      destination, "--template", "./source", "--subdir", name, "--user", "alice",
      "--name", "demo", "-q",
    ])
    assert_eq(result.status, 1, msg=name + ": " + result.stderr)
    assert_true(result.stderr.contains(message), msg=result.stderr)
    assert_false(s.exists(destination), msg=name)
    @fs.mkdir(s.root + "/" + destination)
    let again = s.run([
      destination, "--template", "./source", "--subdir", name, "--name", "demo",
    ])
    assert_eq(again.status, 1)
    assert_eq(
      @fs.readdir(s.root + "/" + destination, include_hidden=true).length(),
      0,
    )
  }
  assert_false(s.exists("escaped"))
}

///|
async test "CLI rejects incompatible repository options before generation" {
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  for
    options in [
      ["--branch", "main"],
      ["--tag", "v1"],
      ["--rev", "a".repeat(40)],
      ["--subdir", "example"],
      ["--template", "missing", "--branch", "main", "--tag", "v1"],
      ["--template", "missing", "--tag", "v1", "--rev", "a".repeat(40)],
    ] {
    let result = s.run(["out"] + options)
    assert_eq(result.status, 2, msg=result.stderr)
    assert_false(s.exists("out"))
  }
}

///|
async fn add_template_link(
  source : String,
  path : String,
  target : String,
) -> Unit {
  let directory = @fs.tmpdir(prefix="moon-new-link-")
  defer @fs.rmdir(directory, recursive=true)
  let file = directory + "/target"
  @fs.write_file(file, target)
  let hash = checked("git", ["hash-object", "-w", file], cwd=source)
    .trim()
    .to_owned()
  ignore(
    checked(
      "git",
      ["update-index", "--add", "--cacheinfo", "120000," + hash + "," + path],
      cwd=source,
    ),
  )
}

///|
async test "CLI preserves expanded relative, dangling and external symbolic links" {
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  ignore(checked("git", ["init", "-b", "main", "source"], cwd=s.root))
  let source = s.root + "/source"
  @fs.mkdir(source + "/dir")
  @fs.write_file(source + "/dir/{{module}}.txt", "{{module}}")
  commit_template(source)
  add_template_link(source, "dir/readme", "{{module}}.txt")
  add_template_link(source, "directory", "dir")
  if !windows() {
    add_template_link(source, "dangling", "missing")
    add_template_link(source, "external", "../outside")
  }
  ignore(
    checked(
      "git",
      [
        "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m",
        "links",
      ],
      cwd=source,
    ),
  )
  @fs.write_file(s.root + "/outside", "do not copy")
  let result = s.run([
    "out", "--template", "./source", "--name", "demo", "--user", "alice",
  ])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_eq(s.read("out/dir/readme"), "demo")
  assert_eq(s.read("out/directory/demo.txt"), "demo")
  if !windows() {
    assert_eq(
      checked("readlink", [s.root + "/out/dir/readme"], cwd=s.root)
      .trim()
      .to_owned(),
      "demo.txt",
    )
    assert_eq(
      checked("readlink", [s.root + "/out/dangling"], cwd=s.root)
      .trim()
      .to_owned(),
      "missing",
    )
    assert_eq(
      checked("readlink", [s.root + "/out/external"], cwd=s.root)
      .trim()
      .to_owned(),
      "../outside",
    )
    assert_eq(result.stderr, "")
  }
}

///|
async test "failed symlinks copy generated files and directories and reject unsafe fallback targets" {
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  ignore(checked("git", ["init", "-b", "main", "source"], cwd=s.root))
  let source = s.root + "/source"
  // Exceed OS link-target limits without changing the referenced project path.
  let prefix = "./".repeat(40000)
  for name in ["file", "directory", "revisit", "missing", "external", "cycle"] {
    @fs.mkdir(source + "/" + name + "/dir", recursive=true)
    @fs.write_file(source + "/" + name + "/dir/data", "{{module}}")
  }
  commit_template(source)
  add_template_link(source, "file/link", prefix + "dir/data")
  add_template_link(source, "directory/link", prefix + "dir")
  add_template_link(source, "revisit/alias", "dir")
  add_template_link(source, "revisit/link", prefix + "alias/../alias/data")
  add_template_link(source, "missing/link", prefix + "absent")
  add_template_link(source, "external/link", prefix + "../outside")
  add_template_link(source, "cycle/link", prefix + "other")
  add_template_link(source, "cycle/other", "link")
  ignore(
    checked(
      "git",
      [
        "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m",
        "fallback",
      ],
      cwd=source,
    ),
  )
  @fs.write_file(s.root + "/outside", "keep")
  for name in ["file", "directory", "revisit", "missing", "external", "cycle"] {
    let result = s.run([
      "out-" + name,
      "--template",
      "./source",
      "--subdir",
      name,
      "--name",
      "demo",
      "-q",
    ])
    assert_true(result.stderr.contains("copying instead"), msg=name)
    assert_eq(result.stdout, "")
    if name == "file" || name == "directory" || name == "revisit" {
      assert_eq(result.status, 0, msg=result.stderr)
      let file = if name == "directory" { "link/data" } else { "link" }
      assert_eq(s.read("out-" + name + "/" + file), "demo")
      assert_true(
        @fs.kind(s.root + "/out-" + name + "/link", follow_symlink=false) !=
        SymLink,
      )
    } else {
      assert_eq(result.status, 1, msg=name)
      assert_false(s.exists("out-" + name), msg=name)
    }
  }
  assert_eq(s.read("outside"), "keep")
}

///|
async test "case aliases cannot turn symlink fallback into writes outside the destination" {
  if windows() {
    return
  }
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  ignore(checked("git", ["init", "-b", "main", "source"], cwd=s.root))
  let source = s.root + "/source"
  @fs.mkdir(source + "/dir")
  @fs.write_file(source + "/dir/file", "payload")
  commit_template(source)
  add_template_link(source, "Alias", "../outside")
  add_template_link(source, "alias", "dir")
  ignore(
    checked(
      "git",
      [
        "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m",
        "aliases",
      ],
      cwd=source,
    ),
  )
  @fs.mkdir(s.root + "/outside")
  @fs.write_file(s.root + "/probe", "")
  let insensitive = s.exists("PROBE")
  let result = s.run(["out", "--template", "./source", "--user", "alice"])
  assert_eq(result.status, if insensitive { 1 } else { 0 }, msg=result.stderr)
  assert_false(s.exists("outside/file"))
  if insensitive {
    assert_false(s.exists("out"))
  }
}

///|
async test "CLI forwards branch tag revision and subdirectory and keeps configuration root local" {
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  ignore(checked("git", ["init", "-b", "main", "source"], cwd=s.root))
  let source = s.root + "/source"
  @fs.write_file(source + "/moon.new.json", "{\"include\":[]}")
  @fs.mkdir(source + "/example")
  @fs.write_file(source + "/example/file", "first {{module}}")
  commit_template(source)
  let revision = checked("git", ["rev-parse", "HEAD"], cwd=source)
    .trim()
    .to_owned()
  ignore(checked("git", ["tag", "v1"], cwd=source))
  @fs.write_file(source + "/example/file", "second {{module}}")
  commit_template(source)
  for
    (selector, value, expected) in [
      ("--branch", "main", "second demo"),
      ("--tag", "v1", "first demo"),
      ("--rev", revision, "first demo"),
    ] {
    let destination = "out" + selector
    let result = s.run([
      destination, "--template", "./source", "--subdir", "example", selector, value,
      "--name", "demo", "--user", "alice",
    ])
    assert_eq(result.status, 0, msg=result.stderr)
    assert_eq(s.read(destination + "/file"), expected)
    assert_false(s.exists(destination + "/example"))
  }
}

///|
async test "Git template write failures roll back files and preserve existing empty destinations" {
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  ignore(checked("git", ["init", "-b", "main", "source"], cwd=s.root))
  let source = s.root + "/source"
  @fs.write_file(source + "/a-first", "created before failure")
  @fs.write_file(source + "/{{module}}", "too long after rendering")
  commit_template(source)
  @fs.mkdir(s.root + "/empty")
  for destination in ["new/parents/out", "empty"] {
    let result = s.run([
      destination,
      "--template",
      "./source",
      "--name",
      "a".repeat(1024),
      "--user",
      "alice",
    ])
    assert_eq(result.status, 1)
    if destination == "empty" {
      assert_eq(@fs.readdir(s.root + "/empty", include_hidden=true).length(), 0)
    } else {
      assert_false(s.exists("new"))
    }
  }
}

///|
async test "quiet Git generation keeps config warnings and ignores source files before rendering" {
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  ignore(checked("git", ["init", "-b", "main", "source"], cwd=s.root))
  let source = s.root + "/source"
  @fs.write_file(
    source + "/moon.new.json",
    "{\"include\":[],\"exclude\":[\"**\"],\"ignore\":[\"bad\"]}",
  )
  @fs.write_file(source + "/bad", "{{unknown}}")
  @fs.write_file(source + "/{{module}}.liquid", "{{unknown}}")
  commit_template(source)
  let result = s.run([
    "out", "--template", "./source", "--name", "demo", "--user", "alice", "-q",
  ])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_eq(result.stdout, "")
  assert_true(result.stderr.contains("exclude"), msg=result.stderr)
  assert_eq(s.read("out/demo.liquid"), "{{unknown}}")
  assert_false(s.exists("out/bad"))
}

///|
async test "CLI anonymous HTTPS generation needs no Git executable" {
  if @env.get_env_var("MOON_NEW_TEST_REMOTE") != Some("1") {
    return
  }
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  s.env["PATH"] = ""
  let result = s.run([
    "out", "--template", "octocat/Hello-World", "--branch", "master", "--user", "alice",
    "-q",
  ])
  assert_eq(result.status, 0, msg=result.stderr)
  assert_eq(s.read("out/README"), "Hello World!\n")
  assert_eq(result.stdout, "")
  assert_eq(s.read("out/.git/HEAD"), "ref: refs/heads/main\n")
}

///|
async test "case aliases in link ancestors cannot write outside the project" {
  if windows() {
    return
  }
  let s = Sandbox::new()
  defer @fs.rmdir(s.root, recursive=true)
  ignore(checked("git", ["init", "-b", "main", "source"], cwd=s.root))
  let source = s.root + "/source"
  @fs.write_file(source + "/file", "payload")
  commit_template(source)
  add_template_link(source, "Alias", "../outside")
  add_template_link(source, "alias/child", "target")
  ignore(
    checked(
      "git",
      [
        "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m",
        "aliases",
      ],
      cwd=source,
    ),
  )
  @fs.mkdir(s.root + "/outside")
  @fs.write_file(s.root + "/probe", "")
  let insensitive = s.exists("PROBE")
  let result = s.run(["out", "--template", "./source", "--user", "alice"])
  assert_eq(result.status, if insensitive { 1 } else { 0 }, msg=result.stderr)
  assert_eq(@fs.readdir(s.root + "/outside", include_hidden=true).length(), 0)
  if insensitive {
    assert_false(s.exists("out"))
  }
}
