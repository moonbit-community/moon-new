///|
fn HostNetwork::socket_allowed(
  self : HostNetwork,
  bind : Bool,
  bytes : Bytes,
) -> Bool raise @sys.HostError {
  guard self.policy is Some(policy) else { return true }
  let address = @sys.decode_address(bytes)
  let ip = @policy.address_ip(address) catch { _ => raise @sys.Invalid }
  policy.allows_socket(bind, ip, address.port()) ||
  (!bind && self.resolved_connect.any(rule => rule.matches(ip, address.port())))
}

///|
fn HostNetwork::authorize_socket(
  self : HostNetwork,
  bind : Bool,
  bytes : Bytes,
) -> Unit raise {
  if !self.socket_allowed(bind, bytes) {
    self.stdio.deny(
      if bind {
        "network bind"
      } else {
        "network connect"
      },
      target=@sys.decode_address(bytes).to_string(),
    )
  }
}

///|
pub fn HostNetwork::resolve_hostname(
  self : HostNetwork,
  name : String,
) -> @resource.Task raise {
  let normalized = @policy.dns_name(name)
  if self.policy is Some(policy) && !policy.allows_lookup(normalized) {
    self.stdio.deny("DNS lookup", target=name)
  }
  let task = @native_jobs.make_native_job(
    ResolveHost,
    name,
    @sys.invalid_native_fd(),
    0,
    0,
    false,
  )
  @resource.Task(task.operation, publish=() => {
    let result = task.publish()
    if result.ret == 0 && result.errno == 0 && self.policy is Some(policy) {
      let data = result.data.to_fixedarray()
      let mut offset = 0
      while offset < data.length() {
        let length = @sys.buffer_word(data, offset, 4).to_int()
        @sys.check_range(offset + 4, length, data.length())
        let ip = @policy.address_ip(
          @sys.decode_address(
            result.data[offset + 4:offset + 4 + length].to_owned(),
          ),
        )
        self.resolved_connect.append(
          policy.resolved_connect_rules(normalized, ip),
        )
        offset += 4 + length
      }
    }
    result
  })
}
