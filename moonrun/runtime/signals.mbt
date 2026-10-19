///|
/// Per-run signal delivery. Embedding applications retain ownership of OS
/// signal handlers and can forward a signal to the active guest explicitly.
pub struct RunControl {
  priv mut deliver : ((Int32) -> Bool raise @vm.RuntimeError)?
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

///|
fn Host::deliver_signal(
  self : Host,
  signal : Int32,
) -> Bool raise @vm.RuntimeError {
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
fn Host::signal_import(
  self : Host,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  match name {
    "signal/get_signal_by_index" => {
      let signal = match i32(args[0]) {
        0 => @signal.Signal::SIGINT
        1 => @signal.Signal::SIGTERM
        2 => @signal.Signal::SIGHUP
        3 => @signal.Signal::SIGBREAK
        _ => return [I32(-1)]
      }
      [I32(signal.to_int())]
    }
    "signal/set_global_cancellation_signals" => {
      // "global" belongs to the guest ABI; never change the host's handlers.
      let memory = guest_memory(caller)
      for argument in [0, 2] {
        let pointer = i32(args[argument]).reinterpret_as_uint().to_int64()
        let length = i32(args[argument + 1])
        guard length >= 0 &&
          pointer + length.to_int64() * 4L <= memory.byte_len() else {
          raise @vm.OutOfBoundsMemoryAccess
        }
      }
      let pointer = i32(args[2]).reinterpret_as_uint().to_int64()
      let length = i32(args[3])
      self.signals.clear()
      for index in 0..<length {
        let signal = memory.load_i32_at(pointer + index.to_int64() * 4L)
        if signal >= 0 {
          self.signals.add(signal)
        }
      }
      []
    }
    "signal/start_signal_handler" => {
      self.signal_enabled = true
      []
    }
    "signal/terminate_signal_handler" => {
      self.signal_enabled = false
      []
    }
    "signal/set_console_control_handler" => {
      self.signal_enabled = i32(args[0]) != 0
      [I32(1)]
    }
    _ => raise @vm.UnknownImport("moonbitlang/async", name)
  }
}

///|
priv struct GuestSignalWaiter {
  interests : Set[Int32]
  ready : @cond_var.Cond
  mut signal : Int32?
}

///|
fn Host::legacy_signal_job(
  self : Host,
  caller : @vm.Caller,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  let count = i32(args[1])
  guard count >= 0 && count <= 0x3FFF_FFFF else {
    raise @vm.OutOfBoundsMemoryAccess
  }
  let bytes = guest_bytes(caller, i32(args[0]), count * 4).to_fixedarray()
  let interests = Set([])
  for index in 0..<count {
    interests.add(buffer_word(bytes, index * 4, 4).to_int())
  }
  let waiter = GuestSignalWaiter::{
    interests,
    ready: @cond_var.Cond(),
    signal: None,
  }
  let key = self.next_handle
  self.new_job(() => {
    self.signal_waiters[key] = waiter
    defer self.signal_waiters.remove(key) |> ignore
    while waiter.signal is None {
      waiter.ready.wait()
    }
    { ret: waiter.signal.unwrap(), errno: 0, data: b"", opened: None, }
  })
}
