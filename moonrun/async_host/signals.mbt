///|
pub fn AsyncHost::deliver_signal(
  self : AsyncHost,
  signal : Int32,
) -> Bool raise @sys.HostError {
  if !self.shutting_down {
    for _, waiter in self.signal_waiters {
      if waiter.signal is None && waiter.interests.contains(signal) {
        waiter.signal = Some(signal)
        let data = FixedArray::makei(4, index => {
          (signal.reinterpret_as_uint() >> (index * 8)).to_byte()
        })
        if @sys.write_guest_pipe(waiter.write, data, 4) != 4 {
          raise @sys.Operation("failed to deliver signal")
        }
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
  write : @sys.Fd
  mut signal : Int32?
}
