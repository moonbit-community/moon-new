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
      if read_init_value(disk, path, key) is Some(value) {
        config[key] = value
      }
    }
  }
  config
}

///|
fn read_init_overrides() -> Map[String, String] {
  let config = Map([])
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
// FIXME(bit-vcs/bit#238): Use the strict parser for lookup and validate
// the template's config before installing it once the parser is released.
fn read_init_value(disk : Disk, path : String, key : String) -> String? {
  @git.read_config_values(disk, path, "init", key).last().map(decode_init_value)
}

///|
// bit returns the raw value, including quotes, escapes and inline comments.
fn decode_init_value(value : String) -> String {
  let result = StringBuilder()
  let whitespace = StringBuilder()
  for rest = value[:], quoted = false; rest is [c, .. tail]; rest = tail {
    match c {
      '#' | ';' if !quoted => break
      ' ' | '\t' if !quoted => whitespace.write_char(c)
      _ => {
        result.write_string(whitespace.to_string())
        whitespace.reset(keep_capacity=true)
        match c {
          '\\' =>
            if tail is [escaped, .. next] {
              result.write_char(
                match escaped {
                  'n' => '\n'
                  't' => '\t'
                  'b' => '\u0008'
                  _ => escaped
                },
              )
              continue next, quoted
            }
          '"' => continue tail, !quoted
          _ => result.write_char(c)
        }
      }
    }
  }
  result.to_string()
}
