///|
fn git_home() -> String? {
  let home = @env.get_env_var("HOME").filter(value => !value.is_empty())
  if home is None && @async.platform is Windows {
    @env.get_env_var("USERPROFILE").filter(value => !value.is_empty())
  } else {
    home
  }
}

///|
fn read_init_config(disk : Disk, home : String?) -> Map[String, String] {
  let files = []
  if @env.get_env_var("GIT_CONFIG_GLOBAL") is Some(path) {
    files.push(path)
  } else {
    let xdg = match
      @env.get_env_var("XDG_CONFIG_HOME").filter(value => !value.is_empty()) {
      Some(path) => Some(path)
      None => home.map(path => path + "/.config")
    }
    if xdg is Some(path) {
      files.push(path + "/git/config")
    }
    if home is Some(path) {
      files.push(path + "/.gitconfig")
    }
  }
  let config = Map([])
  for path in files {
    for key in ["defaultbranch", "templatedir"] {
      if @git.read_config_values(disk, path, "init", key).last() is Some(value) {
        config[key] = decode_init_value(value)
      }
    }
  }
  if @env.get_env_var("GIT_CONFIG_COUNT") is Some(count) {
    let count = @string.parse_int(count) catch { _ => 0 }
    for index in 0..<count {
      guard @env.get_env_var("GIT_CONFIG_KEY_\{index}") is Some(key) &&
        @env.get_env_var("GIT_CONFIG_VALUE_\{index}") is Some(value) else {
        break
      }
      match key.to_lower() {
        "init.defaultbranch" => config["defaultbranch"] = value
        "init.templatedir" => config["templatedir"] = value
        _ => ()
      }
    }
  }
  config
}

///|
// bit returns the raw value, including quotes, escapes and inline comments.
fn decode_init_value(value : String) -> String {
  let result = StringBuilder()
  let mut quoted = false
  let mut escaped = false
  let whitespace = StringBuilder()
  for c in value {
    if escaped {
      result.write_char(
        match c {
          'n' => '\n'
          't' => '\t'
          'b' => '\u0008'
          _ => c
        },
      )
      escaped = false
    } else if !quoted && c is ('#' | ';') {
      break
    } else if !quoted && c is (' ' | '\t') {
      whitespace.write_char(c)
    } else {
      result.write_string(whitespace.to_string())
      whitespace.reset(keep_capacity=true)
      match c {
        '\\' => escaped = true
        '"' => quoted = !quoted
        _ => result.write_char(c)
      }
    }
  }
  result.to_string()
}
