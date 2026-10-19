///|
/// Per-run signal delivery. Embedding applications retain ownership of OS
/// signal handlers and can forward a signal to the active guest explicitly.
pub struct RunControl {
  priv mut deliver : ((Int32) -> Bool raise)?
}

///|
pub fn RunControl::RunControl() -> RunControl {
  { deliver: None, }
}

///|
/// Return false if no guest is running or the guest has not subscribed.
pub fn RunControl::send_signal(self : RunControl, signal : Int32) -> Bool raise {
  match self.deliver {
    Some(deliver) => deliver(signal)
    None => false
  }
}
