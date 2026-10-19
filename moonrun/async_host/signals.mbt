///|
pub fn AsyncHost::deliver_signal(
  self : AsyncHost,
  signal : Int32,
) -> Bool raise @sys.HostError {
  if !self.shutting_down {
    for _, waiter in self.signal_waiters {
      if waiter.signal is None && waiter.interests.contains(signal) {
        waiter.signal = Some(signal)
        waiter.ready.signal()
        return true
      }
    }
  }
  if signal < 0 ||
    !self.signal_enabled ||
    !self.signals.contains(signal) ||
    self.shutting_down {
    return false
  }
  guard self.pool is Some(pool) && !pool.closed && !pool.bus.closed else {
    return false
  }
  pool.notify(signal | (1 << 31))
  true
}

///|
pub(all) struct SignalWaiter {
  interests : Set[Int32]
  ready : @cond_var.Cond
  mut signal : Int32?
}
