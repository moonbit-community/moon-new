///|
pub struct HostNetwork {
  priv policy : @policy.Policy?
  priv resolved_connect : Array[@policy.SocketRule]
  priv stdio : @stdio.Stdio
}

///|
pub fn HostNetwork::HostNetwork(
  policy : @policy.Policy?,
  stdio : @stdio.Stdio,
) -> HostNetwork {
  { policy, resolved_connect: [], stdio, }
}
