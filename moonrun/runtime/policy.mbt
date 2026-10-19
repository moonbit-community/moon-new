///|
priv enum DnsRule {
  Any
  Exact(String)
  Subdomain(String)
}

///|
priv enum SocketHostRule {
  Any
  Ip(@socket.Addr)
  Name(DnsRule)
}

///|
priv struct SocketRule {
  host : SocketHostRule
  port : Int32?
}

///|
priv struct ProcessRule {
  program : String
  args : Array[String]
  windows_prefix : String
}

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
fn dns_name(text : StringView) -> String {
  let text = text.trim()
  let mut end = text.length()
  while end > 0 && text.code_unit_at(end - 1) == '.' {
    end -= 1
  }
  ascii_lower(text[:end])
}

///|
fn DnsRule::parse(text : String) -> DnsRule raise {
  let name = dns_name(text)
  guard !name.is_empty() && name != "*." else {
    raise Failure("empty DNS policy pattern")
  }
  if name == "*" {
    Any
  } else if name.has_prefix("*.") {
    Subdomain(name[2:].to_owned())
  } else {
    Exact(name)
  }
}

///|
fn DnsRule::matches(self : DnsRule, name : String) -> Bool {
  match self {
    Any => true
    Exact(pattern) => name == pattern
    Subdomain(suffix) =>
      name.has_suffix(".\{suffix}") && name.length() > suffix.length() + 1
  }
}

///|
fn address_ip(address : @socket.Addr) -> @socket.Addr raise {
  let text = address.to_string()
  if address.is_ipv6() {
    let end = text.find("]").unwrap()
    let host = text[1:end].to_owned()
    let host = match host.find("%") {
      Some(index) => host[:index].to_owned()
      None => host
    }
    @socket.Addr::parse("[\{host}]:0")
  } else {
    @socket.Addr::new(address.ip(), 0)
  }
}

///|
fn SocketRule::parse(text : String) -> SocketRule raise {
  let (host, port) = if text.has_prefix("[") {
    guard text.find("]:") is Some(end) && end > 1 else {
      raise Failure("IPv6 socket policy rules must use [addr]:port syntax")
    }
    (text[1:end].to_owned(), text[end + 2:].to_owned())
  } else {
    guard text.rev_find(":") is Some(index) &&
      index > 0 &&
      !text[:index].contains_char(':') else {
      raise Failure("socket policy rules must include a host and port")
    }
    (text[:index].to_owned(), text[index + 1:].to_owned())
  }
  let port = if port == "*" {
    None
  } else {
    let port = @string.parse_int(port)
    guard port >= 0 && port <= 65535 else {
      raise Failure("invalid socket policy port")
    }
    Some(port)
  }
  let host = if host == "*" {
    SocketHostRule::Any
  } else {
    let parsed = Some(
      @socket.Addr::parse(
        if host.contains_char(':') {
          "[\{host}]:0"
        } else {
          "\{host}:0"
        },
      ),
    ) catch {
      @socket.InvalidAddr => None
      error => raise error
    }
    match parsed {
      Some(ip) => Ip(ip)
      None => Name(DnsRule::parse(host))
    }
  }
  { host, port, }
}

///|
fn SocketRule::matches(
  self : SocketRule,
  ip : @socket.Addr,
  port : Int32,
) -> Bool {
  (self.port is None || self.port == Some(port)) &&
  (match self.host {
    Any => true
    Ip(expected) => expected == ip
    Name(_) => false
  })
}

///|
fn SocketRule::allows_lookup(self : SocketRule, name : String) -> Bool {
  match self.host {
    Any => true
    Name(pattern) => pattern.matches(name)
    Ip(ip) => {
      let address = Some(
        @socket.Addr::parse(
          if name.contains_char(':') {
            "[\{name}]:0"
          } else {
            "\{name}:0"
          },
        ),
      ) catch {
        _ => None
      }
      address == Some(ip)
    }
  }
}

///|
fn quote_windows_arg(text : String) -> String {
  if text.is_empty() {
    return "\"\""
  }
  if !text.iter().any(c => c is (' ' | '\t' | '"' | '\u0000')) {
    return text
  }
  let output = StringBuilder()
  output.write_char('"')
  let mut slashes = 0
  for c in text {
    if c == '\\' {
      slashes += 1
      continue
    }
    output.write_string(
      String::make(
        slashes * (if c == '"' { 2 } else { 1 }) +
        (if c == '"' { 1 } else { 0 }),
        '\\',
      ),
    )
    slashes = 0
    output.write_char(c)
  }
  output.write_string(String::make(slashes * 2, '\\'))
  output.write_char('"')
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
            @fs.realpath(resolve_from(source_dir, root))
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
fn Policy::environment(
  self : Policy,
  host : Map[String, String],
) -> Map[String, String] raise {
  let result = if self.from_host.contains("*") {
    copy_environment(host)
  } else {
    Map([])
  }
  for key in self.from_host {
    if key != "*" && environment_entry(host, key) is Some((_, value)) {
      set_environment_entry(result, key, value)
    }
  }
  for key in self.required_from_host {
    guard environment_entry(host, key) is Some((_, value)) else {
      raise Failure("required environment variable is not set: \{key}")
    }
    set_environment_entry(result, key, value)
  }
  for key, value in self.set {
    set_environment_entry(result, key, value)
  }
  if environment_entry(result, "MOONRUN_INHERITED_POLICY") is Some((key, _)) {
    result.remove(key)
  }
  result
}

///|
async fn policy_path(path : String, entry : Bool) -> String? {
  let parts : Array[String] = []
  let mut current = path
  if entry {
    parts.push(@path.Path(current).basename().to_owned())
    current = @path.Path(current).dirname().to_string()
  }
  for ;; {
    let canonical = Some(@fs.realpath(current)) catch {
      @os_error.OSError(_, ..) as error if error.is_ENOENT() => None
      _ => return None
    }
    if canonical is Some(canonical) {
      let mut result = canonical
      for i = parts.length() - 1; i >= 0; i = i - 1 {
        result = resolve_from(result, parts[i])
      }
      return Some(@path.Path(result).normalize().to_string())
    }
    let parent = @path.Path(current).dirname().to_string()
    if parent == current || current.is_empty() {
      return None
    }
    parts.push(@path.Path(current).basename().to_owned())
    current = parent
  }
}

///|
fn policy_root_contains(roots : Array[String], path : String) -> Bool {
  roots.any(root => {
    root == "*" ||
    path == root ||
    path.has_prefix(
      root +
      (if root.has_suffix("/") || root.has_suffix("\\") {
        ""
      } else {
        @path.sep.to_string()
      }),
    )
  })
}

///|
async fn Host::deny(
  self : Host,
  action : String,
  target~ : String = "",
) -> Unit {
  self.output(
    2,
    @utf8.encode(
      "Sandbox policy blocked \{action}" +
      (if target.is_empty() { "" } else { ": \{target}" }) +
      "\n",
    ),
  )
  raise @os_error.OSError(
    if @async.platform is Windows {
      5
    } else {
      13
    },
    context="sandbox policy",
  )
}

///|
async fn Host::authorize_path(
  self : Host,
  path : String,
  read~ : Bool = true,
  write~ : Bool = false,
  entry~ : Bool = false,
) -> Unit {
  if self.policy is Some(policy) {
    let canonical = policy_path(path, entry)
    if !(canonical is Some(path) &&
      (!read || policy_root_contains(policy.read, path)) &&
      (!write || policy_root_contains(policy.write, path))) {
      self.deny(
        if read && write {
          "file access"
        } else if write {
          "file write"
        } else {
          "file read"
        },
        target=path,
      )
    }
  }
}

///|
fn Policy::allows_process(
  self : Policy,
  command : String,
  args : Array[String],
) -> Bool {
  self.spawn ||
  self.programs.any(rule => {
    if @async.platform is Windows {
      command == rule.windows_prefix ||
      command.has_prefix(rule.windows_prefix + " ")
    } else {
      command == rule.program &&
      args.get(0) == Some(command) &&
      args.length() > rule.args.length() &&
      rule.args
      .iter()
      .mapi((index, expected) => args[index + 1] == expected)
      .all(value => value)
    }
  })
}

///|
fn Host::socket_allowed(
  self : Host,
  bind : Bool,
  bytes : Bytes,
) -> Bool raise @vm.RuntimeError {
  guard self.policy is Some(policy) else { return true }
  let address = decode_address(bytes)
  let ip = address_ip(address) catch { _ => raise @vm.TypeMismatch }
  let rules = if bind { policy.bind } else { policy.connect }
  rules.any(rule => rule.matches(ip, address.port())) ||
  (!bind && self.resolved_connect.any(rule => rule.matches(ip, address.port())))
}

///|
async fn Host::authorize_socket(
  self : Host,
  bind : Bool,
  bytes : Bytes,
) -> Unit {
  if !self.socket_allowed(bind, bytes) {
    self.deny(
      if bind {
        "network bind"
      } else {
        "network connect"
      },
      target=decode_address(bytes).to_string(),
    )
  }
}

///|
async fn Host::resolve_hostname(self : Host, name : String) -> JobResult {
  let normalized = dns_name(name)
  if self.policy is Some(policy) &&
    !policy.dns.any(rule => rule.matches(normalized)) &&
    !policy.connect.any(rule => rule.allows_lookup(normalized)) {
    self.deny("DNS lookup", target=name)
  }
  let result = run_native_job(
    ResolveHost,
    name,
    invalid_native_fd(),
    0,
    0,
    false,
  )
  if result.ret == 0 && result.errno == 0 && self.policy is Some(policy) {
    let data = result.data.to_fixedarray()
    let mut offset = 0
    while offset < data.length() {
      let length = buffer_word(data, offset, 4).to_int()
      check_range(offset + 4, length, data.length())
      let ip = address_ip(
        decode_address(result.data[offset + 4:offset + 4 + length].to_owned()),
      )
      for rule in policy.connect {
        if rule.host is Name(pattern) && pattern.matches(normalized) {
          self.resolved_connect.push({ host: Ip(ip), port: rule.port, })
        }
      }
      offset += 4 + length
    }
  }
  result
}

///|
async fn Host::authorize_at(
  self : Host,
  path : String,
  parent : GuestFd?,
  follow : Bool,
) -> Unit {
  if self.policy is None {
    return
  }
  let path = if @path.Path(path).is_absolute() || parent is None {
    self.resolve(path)
  } else {
    guard parent is Some(parent) && parent.path is Some(directory) else {
      self.deny("file read", target="<untracked resource>")
      return
    }
    resolve_from(directory, path)
  }
  self.authorize_path(path, entry=!follow)
}

///|
async fn Host::authorize_resource(
  self : Host,
  fd : GuestFd,
  write : Bool,
) -> Unit {
  if self.policy is None {
    return
  }
  guard fd.path is Some(path) else {
    self.deny(
      if write {
        "file write"
      } else {
        "file read"
      },
      target="<untracked resource>",
    )
    return
  }
  self.authorize_path(path, read=!write, write~)
}

///|
fn DnsRule::text(self : DnsRule) -> String {
  match self {
    Any => "*"
    Exact(name) => name
    Subdomain(name) => "*.\{name}"
  }
}

///|
fn SocketRule::text(self : SocketRule) -> String {
  let host = match self.host {
    Any => "*"
    Name(pattern) => pattern.text()
    Ip(address) => {
      let text = address.to_string()
      text[:text.rev_find(":").unwrap()].to_owned()
    }
  }
  host + ":" + self.port.map(port => port.to_string()).unwrap_or("*")
}

///|
fn Policy::inherited_json(self : Policy) -> String {
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

///|
fn invokes_moonx(command : String) -> Bool {
  let program = if @async.platform is Windows {
    let output = StringBuilder()
    let mut quoted = false
    for c in command {
      if c == '"' {
        quoted = !quoted
      } else if !quoted && c is (' ' | '\t') {
        break
      } else {
        output.write_char(c)
      }
    }
    ascii_lower(output.to_string())
  } else {
    command
  }
  let basename = @path.Path(program).basename()
  basename is ("moonx" | "moonx.exe")
}

///|
extern "C" fn adopt_policy_fd(token : UInt64) -> @types.Fd = "moonrun_adopt_policy_fd"

///|
/// Consume an inherited native policy descriptor. The caller transfers ownership
/// of this descriptor and must remove its environment marker before provisioning
/// the guest environment. Invalid transfers fail without running the guest.
pub async fn Policy::from_inherited_handle(token : String) -> Policy {
  let token = @string.parse_uint64(token)
  let fd = adopt_policy_fd(token)
  if fd == invalid_native_fd() {
    @os_error.check_errno("inherited policy handle")
  }
  defer ignore(close_guest_pipe(fd))
  let result = run_native_job(ReadPolicy, "", fd, 0, 0, false)
  if result.ret < 0 {
    raise @os_error.OSError(result.errno, context="inherited policy read")
  }
  Policy::from_json(@utf8.decode(result.data))
}
