///|
fn credentials_path() -> String? {
  if @env.get_env_var("MOON_HOME") is Some(root) {
    return Some(join_path(root, "credentials.json"))
  }
  // Unlike Rust's home::home_dir(), this only checks environment variables:
  // the current MoonBit APIs provide no OS home-directory fallback shared by
  // native and Wasm. If unavailable, the caller warns and uses the default
  // username; users can set MOON_HOME or bypass lookup with --user.
  let root = if @async.platform is Windows {
    @env.get_env_var("USERPROFILE").filter(value => value != "")
  } else {
    @env.get_env_var("HOME")
  }
  root.map(root => join_path(join_path(root, ".moon"), "credentials.json"))
}

///|
async fn existing_username(warnings : Array[String]) -> String? {
  guard credentials_path() is Some(path) else {
    warnings.push(
      "Could not determine the credentials directory; using default username. Set MOON_HOME or pass --user.",
    )
    return None
  }
  if !@fs.exists(path) {
    warnings.push(
      "Using default username. Log in with moon login or pass --user.",
    )
    return None
  }
  let file = @fs.open(path, mode=ReadOnly) catch { _ => return None }
  defer file.close()
  try {
    let value = @json.parse(file.read_all().text())
    guard value is { "token": String(_), .. } else {
      warnings.push(
        "Invalid credentials fields; using default username. Log in again with moon login or pass --user.",
      )
      return None
    }
    match value {
      { "username": String(username), .. } => Some(username)
      { "username": Null, .. } => None
      { "username"? : None, .. } => None
      _ => {
        warnings.push(
          "Invalid credentials fields; using default username. Log in again with moon login or pass --user.",
        )
        None
      }
    }
  } catch {
    // Parser diagnostics can contain source excerpts, so never print them for
    // a credential document that may contain a registry token.
    _ => {
      warnings.push(
        "Could not read or parse credentials; using default username. Log in again with moon login or pass --user.",
      )
      None
    }
  }
}
