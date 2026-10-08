///|
fn validate_names(
  username : String,
  name : String,
  warnings : Array[String],
) -> Unit raise CreationError {
  if username.is_empty() ||
    !username.iter().all(c => @unicode.is_alphanum(c) || c is ('-' | '_')) {
    raise CreationError(
      "Usernames can only contain Unicode alphanumeric characters, dashes (-), and underscores (_), and must not be empty.",
    )
  }
  let mut first = true
  for c in name {
    let letter = c is ('a'..='z' | 'A'..='Z' | '_')
    if !(letter || (!first && c is ('0'..='9' | '-'))) {
      raise CreationError(
        "Invalid project name: \{name}. Expected [A-Za-z_][A-Za-z0-9_-]*.",
      )
    }
    first = false
  }
  if first {
    raise CreationError("Project name must not be empty.")
  }
  if name.has_suffix("_test") || name.has_suffix("_wbtest") {
    warnings.push(
      "Project names ending in _test or _wbtest may conflict with test file conventions.",
    )
  }
}
