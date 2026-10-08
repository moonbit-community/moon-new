///|
async test "package assets regenerate, install, and create a runnable project" {
  let repository = root()
  let temporary = @fs.tmpdir(prefix="moon-new-package-")
  defer @fs.rmdir(temporary, recursive=true)
  let build = temporary + "/build"
  ignore(checked("moon", ["package", "--target-dir", build], cwd=repository))
  let archives = @fs.readdir(build + "/publish").filter(name => {
    name.has_suffix(".zip")
  })
  guard archives is [name] else { fail("expected exactly one package archive") }
  let archive = build + "/publish/" + name
  let source = temporary + "/source"
  @fs.mkdir(source)
  // Use the host archive utility; no extra MoonBit dependency is needed.
  if windows() {
    ignore(checked("tar", ["-xf", archive, "-C", source], cwd=repository))
  } else {
    ignore(checked("unzip", ["-q", archive, "-d", source], cwd=repository))
  }
  // The bundled starter's source assets must survive packaging independently
  // of how dev_build rules are written in moon.pkg.
  let inputs = [
    "moon.pkg", "moon.mod", "cmd/main/moon.pkg", "cmd/main/main.mbt", "{{package}}.mbt",
    "{{package}}_test.mbt", "{{package}}_wbtest.mbt", ".githooks/README.md", ".githooks/pre-commit",
    "LICENSE", "README.mbt.md", ".gitignore", ".github/workflows/copilot-setup-steps.yml",
    "AGENTS.md",
  ]
  for path in inputs {
    assert_eq(
      @fs.read_file(source + "/template/assets/" + path).binary(),
      @fs.read_file(repository + "/template/assets/" + path).binary(),
      msg=path,
    )
  }
  let generated = @fs.readdir(repository + "/template").filter(name => {
    name.has_suffix(".generated.mbt")
  })
  assert_eq(generated.length(), inputs.length())
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
