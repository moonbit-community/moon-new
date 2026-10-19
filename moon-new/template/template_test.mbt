///|
test "render the fixed default project without changing Unicode or newlines" {
  let entries = @template.render("用户𐐀", "hello")
  assert_eq(entries.length(), 15)
  let mut readme = None
  let mut hook = None
  for entry in entries {
    match entry {
      File(path="README.mbt.md", content~, ..) => readme = Some(content)
      File(path=".githooks/pre-commit", content~, executable~) =>
        hook = Some((content, executable))
      _ => ()
    }
  }
  assert_eq(readme, Some(@utf8.encode("# 用户𐐀/hello")))
  assert_eq(hook, Some((b"#!/bin/sh\n\nmoon check", true)))
}
