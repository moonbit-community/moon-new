///|
fn validate_names(
  username : String,
  name : String,
  warnings : Array[String],
) -> Unit raise CreationError {
  if username == "" ||
    !username.iter().all(c => @unicode.is_alphanum(c) || c == '-' || c == '_') {
    raise CreationError(
      "Usernames can only contain Unicode alphanumeric characters, dashes (-), and underscores (_), and must not be empty.",
    )
  }
  let mut first = true
  for c in name {
    let letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
    if !(letter || (!first && ((c >= '0' && c <= '9') || c == '-'))) {
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
