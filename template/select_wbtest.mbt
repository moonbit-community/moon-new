///|
test "Gitignore character groups and escapes select file contents" {
  let cases : Array[(String, String, Bool)] = [
    ("[ab].txt", "a.txt", true),
    ("[ab].txt", "c.txt", false),
    ("[0-9].txt", "3.txt", true),
    ("[!0-9].txt", "a.txt", true),
    ("[!0-9].txt", "3.txt", false),
    ("file\\?.txt", "file?.txt", true),
    ("file\\?.txt", "file1.txt", false),
    ("file\\*.txt", "file*.txt", true),
    ("file\\*.txt", "file-many.txt", false),
    ("\\[x\\].txt", "[x].txt", true),
    ("\\!file", "!file", true),
    ("\\#file", "#file", true),
    ("file\\ ", "file ", true),
    ("file ", "file", true),
    ("a/**/file", "a/file", true),
    ("a/**/file", "a/b/c/file", true),
    ("a/*/file", "a/b/c/file", false),
    ("**/file", "file", true),
    ("**/file", "a/b/file", true),
    ("dir/**", "dir", false),
    ("dir/**", "dir/a/b", true),
    ("{a,b}.txt", "a.txt", true),
    ("{a,b}.txt", "c.txt", false),
    ("{{a,b},c}.txt", "b.txt", true),
    ("\\{\\{module\\}\\}.txt", "{{module}}.txt", true),
    ("[abc", "[abc", true),
    ("[]a].txt", "].txt", true),
    ("[-ab].txt", "-.txt", true),
    ("[ab-].txt", "-.txt", true),
    ("?", "é", false),
    ("??", "é", true),
    ("é", "é", true),
    ("[é]", "é", false),
    ("[é][é]", "é", true),
    ("{,a}.txt", ".txt", false),
    ("{}.txt", ".txt", true),
    ("{}", "file", true),
    ("**/", "file", true),
    ("/", "file", true),
    ("[a-c-e]", "-", false),
    ("[a-c-e]", "d", true),
    ("{**,a}/x", "a/b/x", false),
    ("{**,a}/x", "a/x", true),
    ("{a,**}/x", "a/b/x", false),
  ]
  for (pattern, path, expected) in cases {
    let config : Json = { "include": [pattern] }
    let selected = select([
      @repository.Entry::{
        path: "moon.new.json",
        mode: "100644",
        content: @utf8.encode(config.stringify()),
      },
      @repository.Entry::{ path, mode: "100644", content: b"{{module}}", },
    ])
    assert_eq(selected.length(), 1)
    assert_eq(selected[0].1, expected, msg="\{pattern} against \{path}")
  }
}

///|
test "invalid Gitignore patterns report the source pattern" {
  for pattern in ["[z-a]", "file\\", "{unclosed", "unopened}"] {
    let config : Json = { "include": [pattern] }
    try
      select([
        @repository.Entry::{
          path: "moon.new.json",
          mode: "100644",
          content: @utf8.encode(config.stringify()),
        },
      ])
    catch {
      error => {
        assert_true(error.to_string().contains("moon.new.json"))
        assert_true(error.to_string().contains(pattern))
      }
    } noraise {
      _ => fail("Expected invalid pattern: \{pattern}")
    }
  }
}
