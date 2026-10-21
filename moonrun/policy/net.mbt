///|
priv enum DnsRule {
  Any
  Exact(String)
  Subdomain(String)
}

///|
priv enum SocketHostRule {
  Any
  Ip(@sys.Addr)
  Name(DnsRule)
}

///|
pub struct SocketRule {
  priv host : SocketHostRule
  priv port : Int32?
}

///|
pub fn dns_name(text : StringView) -> String {
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
pub fn address_ip(address : @sys.Addr) -> @sys.Addr raise {
  let text = address.to_string()
  if address.is_ipv6() {
    let end = text.find("]").unwrap()
    let host = text[1:end].to_owned()
    let host = match host.find("%") {
      Some(index) => host[:index].to_owned()
      None => host
    }
    @sys.Addr::parse("[\{host}]:0")
  } else {
    @sys.Addr::new(address.ip(), 0)
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
      @sys.Addr::parse(
        if host.contains_char(':') {
          "[\{host}]:0"
        } else {
          "\{host}:0"
        },
      ),
    ) catch {
      @sys.InvalidAddr => None
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
pub fn SocketRule::matches(
  self : SocketRule,
  ip : @sys.Addr,
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
        @sys.Addr::parse(
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
pub fn Policy::allows_socket(
  self : Policy,
  bind : Bool,
  ip : @sys.Addr,
  port : Int32,
) -> Bool {
  let rules = if bind { self.bind } else { self.connect }
  rules.any(rule => rule.matches(ip, port))
}

///|
pub fn Policy::allows_lookup(self : Policy, name : String) -> Bool {
  self.dns.any(rule => rule.matches(name)) ||
  self.connect.any(rule => rule.allows_lookup(name))
}

///|
pub fn Policy::resolved_connect_rules(
  self : Policy,
  name : String,
  ip : @sys.Addr,
) -> Array[SocketRule] {
  self.connect.filter_map(rule => {
    if rule.host is Name(pattern) && pattern.matches(name) {
      Some({ host: Ip(ip), port: rule.port, })
    } else {
      None
    }
  })
}
