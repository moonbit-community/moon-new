///|
async test "package assets regenerate, install, and create a runnable project" {
  let repository = root()
  ignore(checked("moon", ["package"], cwd=repository))
  let archive = repository +
    "/_build/publish/moonbit-community-moon-new-0.1.0.zip"
  let temporary = @fs.tmpdir(prefix="moon-new-package-")
  defer @fs.rmdir(temporary, recursive=true)
  let source = temporary + "/source"
  @fs.mkdir(source)
  // Use the host archive utility; no extra MoonBit dependency is needed.
  if windows() {
    ignore(checked("tar", ["-xf", archive, "-C", source], cwd=repository))
  } else {
    ignore(checked("unzip", ["-q", archive, "-d", source], cwd=repository))
  }
  let inputs = []
  let manifest = @fs.read_file(repository + "/template/moon.pkg").text()
  for line in manifest.split("\n") {
    if line.trim().strip_prefix("input: \"") is Some(value) {
      guard value.strip_suffix("\",") is Some(value) else {
        fail("unexpected dev_build input")
      }
      inputs.push("template/" + value.to_owned())
    }
  }
  assert_eq(inputs.length(), 14)
  for path in inputs {
    assert_eq(
      @fs.read_file(source + "/" + path).binary(),
      @fs.read_file(repository + "/" + path).binary(),
      msg=path,
    )
  }
  let generated = @fs.readdir(repository + "/template").filter(name => {
    name.has_suffix(".generated.mbt")
  })
  assert_eq(generated.length(), 14)
  for name in generated {
    let relative = "/template/" + name
    assert_eq(
      @fs.read_file(source + relative).binary(),
      @fs.read_file(repository + relative).binary(),
      msg=name,
    )
    @fs.remove(source + relative)
  }
  assert_false(@fs.exists(source + "/tests"))
  assert_false(@fs.exists(source + "/_build"))
  let binary_dir = temporary + "/bin"
  ignore(
    checked(
      "moon",
      ["install", "--path", source, "--bin", binary_dir],
      cwd=repository,
    ),
  )
  for name in generated {
    let relative = "/template/" + name
    assert_eq(
      @fs.read_file(source + relative).binary(),
      @fs.read_file(repository + relative).binary(),
      msg=name,
    )
  }
  let installed = binary_dir +
    (if windows() { "/moon-new.exe" } else { "/moon-new" })
  assert_true(@fs.exists(installed))
  let destination = temporary + "/generated"
  ignore(
    checked(
      installed,
      [destination, "--user", "tester", "--quiet"],
      cwd=temporary,
    ),
  )
  ignore(checked("moon", ["check"], cwd=destination))
  ignore(checked("moon", ["test"], cwd=destination))
  assert_eq(
    checked("moon", ["run", "cmd/main"], cwd=destination).trim().to_owned(),
    "Hello",
  )
}
