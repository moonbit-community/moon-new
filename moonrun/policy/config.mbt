///|
/// Construction-time policy. Supplying any policy enables deny-by-default
/// authorization; environment provisioning is applied independently per run.
pub struct Policy {
  priv read : Array[String]
  priv write : Array[String]
  priv dns : Array[DnsRule]
  priv connect : Array[SocketRule]
  priv bind : Array[SocketRule]
  priv from_host : Array[String]
  priv required_from_host : Array[String]
  priv set : Map[String, String]
  priv spawn : Bool
  priv programs : Array[ProcessRule]
}

///|
fn policy_fields(
  value : Json,
  allowed : Array[String],
) -> Map[String, Json] raise {
  guard value is Object(fields) else {
    raise Failure("policy section must be an object")
  }
  for key, _ in fields {
    guard allowed.contains(key) else {
      raise Failure("unknown policy field: \{key}")
    }
  }
  fields
}

///|
fn policy_section(
  value : Json?,
  allowed : Array[String],
) -> Map[String, Json] raise {
  match value {
    None | Some(Null) => Map([])
    Some(value) => policy_fields(value, allowed)
  }
}

///|
fn policy_strings(value : Json?) -> Array[String] raise {
  match value {
    None => []
    Some(Array(values)) =>
      values.map(value => {
        guard value is String(text) else {
          raise Failure("policy list must contain strings")
        }
        text
      })
    _ => raise Failure("policy value must be an array of strings")
  }
}

///|
fn ascii_lower(text : StringView) -> String {
  let output = StringBuilder()
  for c in text {
    output.write_char(c.to_ascii_lowercase())
  }
  output.to_string()
}

///|
pub async fn Policy::from_json(
  contents : String,
  source_dir~ : String = @env.current_dir().unwrap_or("."),
) -> Policy {
  Policy::from_value(
    @json.parse(contents, reject_duplicate_keys=true),
    source_dir,
  )
}

///|
async fn Policy::from_value(value : Json, source_dir : String) -> Policy {
  let fields = policy_fields(value, ["fs", "net", "env", "process"])
  let fs = policy_section(fields.get("fs"), ["read", "write"])
  let roots = async fn(value : Json?) {
    @async.all(
      policy_strings(value).map(root => {
        async fn() {
          if root == "*" {
            root
          } else {
            @fs.realpath(@working_directory.resolve_from(source_dir, root))
          }
        }
      }),
    )
  }
  let read = roots(fs.get("read"))
  let write = roots(fs.get("write"))
  let net = policy_section(fields.get("net"), ["dns", "connect", "bind"])
  let dns = policy_strings(net.get("dns")).map(DnsRule::parse)
  let connect = policy_strings(net.get("connect")).map(SocketRule::parse)
  let bind = policy_strings(net.get("bind")).map(SocketRule::parse)
  guard bind.all(rule => !(rule.host is Name(_))) else {
    raise Failure("bind policy rules must use an IP address or *")
  }
  let env = policy_section(fields.get("env"), [
    "from_host", "required_from_host", "set",
  ])
  let from_host = policy_strings(env.get("from_host"))
  let required_from_host = policy_strings(env.get("required_from_host"))
  let set : Map[String, String] = Map([])
  if env.get("set") is Some(value) {
    guard value is Object(values) else {
      raise Failure("env.set must be an object")
    }
    for key, value in values {
      guard value is String(value) else {
        raise Failure("env.set values must be strings")
      }
      set[key] = value
    }
  }
  for key in [..from_host, ..required_from_host, ..set.keys().to_array()] {
    guard !key.is_empty() &&
      !key.contains_char('\u0000') &&
      !key.contains_char('=') else {
      raise Failure("invalid environment policy key")
    }
  }
  guard required_from_host.all(key => key != "*") else {
    raise Failure("required_from_host does not accept *")
  }
  guard set.values().all(value => !value.contains_char('\u0000')) else {
    raise Failure("environment policy values must not contain NUL")
  }
  let process = policy_section(fields.get("process"), ["spawn", "allow"])
  let spawn = match process.get("spawn") {
    None => false
    Some(True) => true
    Some(False) => false
    _ => raise Failure("process.spawn must be a boolean")
  }
  let rules = match process.get("allow") {
    None => []
    Some(Array(values)) => values
    _ => raise Failure("process.allow must be an array")
  }
  guard !spawn || rules.is_empty() else {
    raise Failure("process.spawn and process.allow cannot be used together")
  }
  let programs = rules.map(value => {
    let fields = policy_fields(value, ["program", "args_prefix"])
    guard fields.get("program") is Some(String(program)) &&
      !program.is_empty() &&
      !program.contains_char('\u0000') else {
      raise Failure("process program must not be empty or contain NUL")
    }
    let args = policy_strings(fields.get("args_prefix"))
    guard args.all(arg => !arg.contains_char('\u0000')) else {
      raise Failure("args_prefix must not contain NUL")
    }
    let lower = ascii_lower(program)
    let command = if lower.has_suffix(".exe") || lower.has_suffix(".com") {
      program
    } else {
      program + ".exe"
    }
    let windows_prefix = [
      quote_windows_arg(command),
      ..args.map(quote_windows_arg),
    ].join(" ")
    ProcessRule::{ program, args, windows_prefix, }
  })
  {
    read,
    write,
    dns,
    connect,
    bind,
    from_host,
    required_from_host,
    set,
    spawn,
    programs,
  }
}

///|
pub fn Policy::environment(
  self : Policy,
  host : Map[String, String],
) -> Map[String, String] raise {
  let result = if self.from_host.contains("*") {
    @environment.copy_environment(host)
  } else {
    Map([])
  }
  for key in self.from_host {
    if key != "*" &&
      @environment.environment_entry(host, key) is Some((_, value)) {
      @environment.set_environment_entry(result, key, value)
    }
  }
  for key in self.required_from_host {
    guard @environment.environment_entry(host, key) is Some((_, value)) else {
      raise Failure("required environment variable is not set: \{key}")
    }
    @environment.set_environment_entry(result, key, value)
  }
  for key, value in self.set {
    @environment.set_environment_entry(result, key, value)
  }
  if @environment.environment_entry(result, "MOONRUN_INHERITED_POLICY")
    is Some((key, _)) {
    result.remove(key)
  }
  result
}

///|
pub fn Policy::inherited_json(self : Policy) -> String {
  let value : Json = {
    "fs": { "read": self.read, "write": self.write },
    "net": {
      "dns": self.dns.map(rule => rule.text()),
      "connect": self.connect.map(rule => rule.text()),
      "bind": self.bind.map(rule => rule.text()),
    },
    "env": { "from_host": ["*"] },
    "process": {
      "spawn": self.spawn,
      "allow": self.programs.map(rule => {
        ({ "program": rule.program, "args_prefix": rule.args } : Json)
      }),
    },
  }
  value.stringify()
}
