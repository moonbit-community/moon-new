///|
fn Context::event_bus_import(
  self : Context,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.async_host
  if name == "event_bus/create" {
    return {
      let bus = @sys.EventBus::new()
      let handle = self.runtime.handles.allocate()
      host.buses[handle] = bus
      [I64(handle)]
    }
  }
  if name == "event_bus/event_fd" ||
    name == "event_bus/event_events/unix" ||
    name == "event_bus/event_bytes_transferred/windows" ||
    name == "event_bus/event_pid" ||
    name == "event_bus/event_io_result/windows" {
    guard host.current_bus is Some(handle) &&
      host.buses.get(handle) is Some(bus) else {
      raise @vm.TypeMismatch
    }
    let index = i64(args[0])
    guard index >= 0L && index < @sys.event_wait_result(bus.native).to_int64() else {
      raise @vm.TypeMismatch
    }
    return if name == "event_bus/event_fd" {
      [I64(@sys.event_fd(bus.native, index.to_int()))]
    } else if name == "event_bus/event_events/unix" {
      [I32(@sys.event_flags(bus.native, index.to_int()))]
    } else if name == "event_bus/event_io_result/windows" {
      let token = @sys.event_token(bus.native, index.to_int())
      if @sys.platform is Windows {
        guard host.io_results.get(token) is Some(result) else {
          raise @vm.TypeMismatch
        }
        result.pending = false
      }
      [I64(token)]
    } else if name == "event_bus/event_pid" {
      [I32(@sys.event_pid(bus.native, index.to_int()))]
    } else {
      [I32(@sys.event_bytes(bus.native, index.to_int()))]
    }
  }
  guard host.buses.get(i64(args[0])) is Some(bus) else {
    if name == "event_bus/try_register" || name == "event_bus/wait" {
      host.async_errno = @sys.bad_fd_errno
      return [I32(-1)]
    }
    raise @vm.TypeMismatch
  }
  match name {
    "event_bus/destroy" => {
      let handle = i64(args[0])
      host.buses.remove(handle)
      if host.current_bus == Some(handle) {
        host.current_bus = None
      }
      bus.close()
      []
    }
    "event_bus/try_register" => {
      let handle = i64(args[1])
      if self.runtime.process.process_handles.get(handle) is Some(process) {
        let result = @sys.register_event_fd(
          bus.native,
          match process {
            @process.Child(child) =>
              match child.completion {
                Some(pipe) => pipe[0]
                None => @sys.child_handle(child.native)
              }
            External(process) => process.fd
          },
          true,
          handle,
        )
        if result < 0 {
          host.async_errno = @sys.get_errno()
        }
        return [I32(result)]
      }
      guard host.fds.get(handle) is Some(fd) else {
        host.async_errno = @sys.bad_fd_errno
        return [I32(-1)]
      }
      if !(@sys.platform is Windows) &&
        fd.owner is Standard(id, _) &&
        (
          (id == 0 && self.runtime.stdio.stdin is Some(_)) ||
          (id == 1 && self.runtime.stdio.stdout is Some(_)) ||
          (id == 2 && self.runtime.stdio.stderr is Some(_))
        ) {
        // Callback streams have no kernel fd. Let the guest use worker jobs.
        return [I32(0)]
      }
      let result = if @sys.platform is Windows {
        // Native async owns the HANDLE's IOCP. Guest I/O results post their
        // completion into this bus without associating the HANDLE twice.
        for other_handle, other in host.buses {
          if other_handle != i64(args[0]) &&
            !other.closed &&
            other.registered.contains(handle) {
            host.async_errno = 87
            return [I32(-1)]
          }
        }
        1
      } else {
        @sys.register_event_fd(
          bus.native,
          fd.native(),
          i32(args[2]) != 0,
          handle,
        )
      }
      if result > 0 {
        bus.registered.add(handle)
      }
      if result < 0 {
        host.async_errno = @sys.get_errno()
      }
      [I32(result)]
    }
    "event_bus/get_event" => {
      let index = i32(args[1])
      guard host.current_bus == Some(i64(args[0])) &&
        index >= 0 &&
        index < @sys.event_wait_result(bus.native) else {
        raise @vm.TypeMismatch
      }
      [I64(index.to_int64())]
    }
    "event_bus/wait" => {
      let timeout = i32(args[1])
      let count = self.wait_events(bus, timeout)
      if count < 0 {
        host.async_errno = @sys.event_wait_errno(bus.native)
      } else {
        host.current_bus = Some(i64(args[0]))
      }
      [I32(count)]
    }
    _ => raise @vm.UnknownImport("moonbitlang/async", name)
  }
}

///|
fn Context::wait_events(
  self : Context,
  bus : @sys.EventBus,
  timeout : Int32,
) -> Int32 raise {
  let deadline = @wasi.native_clock_gettime_monotonic() +
    timeout.to_int64() * 1000000L
  for ;; {
    self.progress()
    let remaining = if timeout < 0 {
      10
    } else {
      @cmp.maximum(
        0L,
        (deadline - @wasi.native_clock_gettime_monotonic() + 999999L) / 1000000L,
      ).to_int()
    }
    let count = bus.wait(@cmp.minimum(remaining, 10))
    self.progress()
    if count != 0 ||
      (timeout >= 0 && @wasi.native_clock_gettime_monotonic() >= deadline) {
      return count
    }
  }
}
