///|
fn toml_policy_value(value : @toml.TomlValue) -> Json raise {
  match value {
    TomlString(text) => Json::string(text)
    TomlBoolean(value) => Json::boolean(value)
    TomlInteger(value) => Json::number(value.to_double())
    TomlFloat(value) => Json::number(value)
    TomlArray(values) => Json::array(values.map(toml_policy_value))
    TomlTable(fields) =>
      Json::object(fields.map((_, value) => toml_policy_value(value)))
    TomlDateTime(_) =>
      raise Failure("date/time values are not supported in policies")
  }
}

///|
fn mbtx_comment(line : StringView) -> StringView? {
  guard line.trim_start().strip_prefix("//") is Some(comment) else {
    return None
  }
  guard comment.is_empty() || comment[0] is (' ' | '\t') else { return None }
  Some(comment.strip_prefix(" ").unwrap_or(comment))
}

///|
fn mbtx_policy_value(content : String) -> Json raise {
  let content = content[:].strip_prefix("\u{feff}").unwrap_or(content[:])
  let lines = content.split("\n")
  guard lines.find_first(line => !line.trim().is_empty()) is Some(first) &&
    mbtx_comment(first.strip_suffix("\r").unwrap_or(first)) is Some(first) &&
    first.trim().has_prefix("policy:") else {
    raise Failure(".mbtx policy source has no `// policy:` front matter")
  }
  let yaml = StringBuilder()
  yaml.write_string(first.to_owned())
  yaml.write_char('\n')
  for line in lines {
    guard mbtx_comment(line.strip_suffix("\r").unwrap_or(line)) is Some(comment) &&
      (comment.is_empty() || comment[0] is (' ' | '\t')) else {
      break
    }
    yaml.write_string(comment.to_owned())
    yaml.write_char('\n')
  }
  parse_policy_yaml(yaml.to_string())
}

///|
/// Load JSON, TOML, or leading `.mbtx` YAML comments. Relative filesystem roots
/// use the document directory, unless a source directory is supplied explicitly.
pub fn Policy::load_file(path : String, source_dir? : String) -> Policy raise {
  let content = @sys.read_file_to_string(path)
  let extension = ascii_lower(@path.Path(path).extname())
  let value = if extension == ".mbtx" {
    mbtx_policy_value(content)
  } else if extension == ".json" || content.trim_start().has_prefix("{") {
    @json.parse(content, reject_duplicate_keys=true)
  } else {
    toml_policy_value(@toml.parse(content))
  }
  Policy::from_value(
    value,
    source_dir.unwrap_or_else(() => @path.Path(path).dirname().to_string()),
  )
}
