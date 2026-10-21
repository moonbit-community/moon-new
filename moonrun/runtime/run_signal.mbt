///|
/// Per-run signal delivery. Embedding applications retain ownership of OS
/// signal handlers and can forward a signal to the active guest explicitly.
pub struct RunControl {
  priv poll : (() -> Int32?)?
  priv mut deliver : ((Int32) -> Bool raise)?
}

///|
/// Poll at guest execution checkpoints, including while waiting for host work.
/// A returned signal is delivered to the guest, or terminates it if unhandled.
pub fn RunControl::RunControl(poll? : () -> Int32?) -> RunControl {
  { deliver: None, poll, }
}

///|
/// Return false if no guest is running or the guest has not subscribed.
pub fn RunControl::send_signal(self : RunControl, signal : Int32) -> Bool raise {
  match self.deliver {
    Some(deliver) => deliver(signal)
    None => false
  }
}
