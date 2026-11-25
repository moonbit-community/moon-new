///|
test "render the fixed default project without changing Unicode or newlines" {
  let entries = @template.render("用户𐐀", "hello")
  assert_eq(entries.length(), 15)
  let (readme, hook) = for entry in entries; readme = None, hook = None {
    match entry {
      File(path="README.mbt.md", content~, ..) => continue Some(content), hook
      File(path=".githooks/pre-commit", content~, executable~) =>
        continue readme, Some((content, executable))
      _ => ()
    }
  } nobreak {
    (readme, hook)
  }
  assert_eq(readme, Some(@utf8.encode("# 用户𐐀/hello")))
  assert_eq(hook, Some((b"#!/bin/sh\n\nmoon check", true)))
}
