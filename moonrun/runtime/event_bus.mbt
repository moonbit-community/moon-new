///|
#external
priv type NativeEventBus

///|
extern "C" fn create_event_bus(fd : @types.Fd) -> NativeEventBus = "moonrun_event_bus_create"

///|
extern "C" fn event_bus_is_null(bus : NativeEventBus) -> Bool = "moonrun_event_bus_is_null"

///|
extern "C" fn close_event_bus(bus : NativeEventBus) -> Unit = "moonrun_event_bus_close"

///|
extern "C" fn begin_event_wait(bus : NativeEventBus, timeout : Int32) -> Unit = "moonrun_event_bus_begin"

///|
extern "C" fn event_wait_result(bus : NativeEventBus) -> Int32 = "moonrun_event_bus_result"

///|
extern "C" fn event_wait_errno(bus : NativeEventBus) -> Int32 = "moonrun_event_bus_errno"

///|
extern "C" fn register_event_fd(
  bus : NativeEventBus,
  fd : @types.Fd,
  read_only : Bool,
  key : Int64,
) -> Int32 = "moonrun_event_bus_register"

///|
extern "C" fn event_fd(bus : NativeEventBus, index : Int32) -> Int64 = "moonrun_event_bus_event_fd"

///|
extern "C" fn event_flags(bus : NativeEventBus, index : Int32) -> Int32 = "moonrun_event_bus_event_flags"

///|
extern "C" fn event_bytes(bus : NativeEventBus, index : Int32) -> Int32 = "moonrun_event_bus_event_bytes"

///|
extern "C" fn event_token(bus : NativeEventBus, index : Int32) -> Int64 = "moonrun_event_bus_event_token"

///|
extern "C" fn event_pid(bus : NativeEventBus, index : Int32) -> Int32 = "moonrun_event_bus_event_pid"

///|
extern "C" fn register_completion_fd(
  bus : NativeEventBus,
  fd : @types.Fd,
  key : Int64,
) -> Int32 = "moonrun_event_bus_register_completion"

///|
extern "C" fn post_completion(
  bus : NativeEventBus,
  key : Int64,
  token : Int64,
  bytes : Int32,
) -> Int32 = "moonrun_event_bus_post"

///|
priv struct GuestEventBus {
  native : NativeEventBus
  read : @pipe.PipeRead
  mut closed : Bool
  registered : Set[Int64]
}

///|
fn GuestEventBus::new() -> GuestEventBus raise {
  let (read, write) = @pipe.pipe()
  errdefer read.close()
  defer write.close()
  let native = create_event_bus(write.fd())
  guard !event_bus_is_null(native) else {
    raise @vm.LinkErrorDetail("failed to create guest event bus")
  }
  { native, read, closed: false, registered: Set([]), }
}

///|
fn GuestEventBus::close(self : GuestEventBus) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  // Stop and join the C worker before releasing the notification reader.
  close_event_bus(self.native)
  self.read.close()
}

///|
async fn GuestEventBus::wait(self : GuestEventBus, timeout : Int32) -> Int32 {
  begin_event_wait(self.native, timeout)
  // Only this task accesses the pipe. Cancellation unwinds to Host::close,
  // which wakes the native wait and joins it without accessing the MoonBit heap.
  ignore(self.read.read_exactly(1))
  event_wait_result(self.native)
}

///|
fn Host::event_bus_import(
  self : Host,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  if name == "event_bus/create" {
    return self.suspend(() => {
      let bus = GuestEventBus::new()
      let handle = self.next_handle
      self.next_handle += 1L
      self.buses[handle] = bus
      [I64(handle)]
    })
  }
  if name == "event_bus/event_fd" ||
    name == "event_bus/event_events/unix" ||
    name == "event_bus/event_bytes_transferred/windows" ||
    name == "event_bus/event_pid" ||
    name == "event_bus/event_io_result/windows" {
    guard self.current_bus is Some(handle) &&
      self.buses.get(handle) is Some(bus) else {
      raise @vm.TypeMismatch
    }
    let index = i64(args[0])
    guard index >= 0L && index < event_wait_result(bus.native).to_int64() else {
      raise @vm.TypeMismatch
    }
    return if name == "event_bus/event_fd" {
      [I64(event_fd(bus.native, index.to_int()))]
    } else if name == "event_bus/event_events/unix" {
      [I32(event_flags(bus.native, index.to_int()))]
    } else if name == "event_bus/event_io_result/windows" {
      let token = event_token(bus.native, index.to_int())
      if @async.platform is Windows {
        guard self.io_results.get(token) is Some(result) else {
          raise @vm.TypeMismatch
        }
        result.pending = false
      }
      [I64(token)]
    } else if name == "event_bus/event_pid" {
      [I32(event_pid(bus.native, index.to_int()))]
    } else {
      [I32(event_bytes(bus.native, index.to_int()))]
    }
  }
  guard self.buses.get(i64(args[0])) is Some(bus) else {
    if name == "event_bus/try_register" || name == "event_bus/wait" {
      self.async_errno = bad_fd_errno
      return [I32(-1)]
    }
    raise @vm.TypeMismatch
  }
  match name {
    "event_bus/destroy" => {
      let handle = i64(args[0])
      self.buses.remove(handle)
      if self.current_bus == Some(handle) {
        self.current_bus = None
      }
      bus.close()
      []
    }
    "event_bus/try_register" => {
      let handle = i64(args[1])
      if self.process_handles.get(handle) is Some(process) {
        let result = register_event_fd(
          bus.native,
          match process {
            Child(child) =>
              match child.completion {
                Some(pipe) => pipe[0]
                None => child_handle(child.native)
              }
            External(process) => process.fd
          },
          true,
          handle,
        )
        if result < 0 {
          self.async_errno = @os_error.get_errno()
        }
        return [I32(result)]
      }
      guard self.fds.get(handle) is Some(fd) else {
        self.async_errno = bad_fd_errno
        return [I32(-1)]
      }
      if !(@async.platform is Windows) &&
        fd.owner is Standard(id, _) &&
        (
          (id == 0 && self.stdin is Some(_)) ||
          (id == 1 && self.stdout is Some(_)) ||
          (id == 2 && self.stderr is Some(_))
        ) {
        // Callback streams have no kernel fd. Let the guest use worker jobs.
        return [I32(0)]
      }
      let result = if @async.platform is Windows {
        // Native async owns the HANDLE's IOCP. Guest I/O results post their
        // completion into this bus without associating the HANDLE twice.
        for other_handle, other in self.buses {
          if other_handle != i64(args[0]) &&
            !other.closed &&
            other.registered.contains(handle) {
            self.async_errno = 87
            return [I32(-1)]
          }
        }
        1
      } else {
        register_event_fd(bus.native, fd.native(), i32(args[2]) != 0, handle)
      }
      if result > 0 {
        bus.registered.add(handle)
      }
      if result < 0 {
        self.async_errno = @os_error.get_errno()
      }
      [I32(result)]
    }
    "event_bus/get_event" => {
      let index = i32(args[1])
      guard self.current_bus == Some(i64(args[0])) &&
        index >= 0 &&
        index < event_wait_result(bus.native) else {
        raise @vm.TypeMismatch
      }
      [I64(index.to_int64())]
    }
    "event_bus/wait" => {
      let timeout = i32(args[1])
      self.suspend(() => {
        let count = bus.wait(timeout)
        if count < 0 {
          self.async_errno = event_wait_errno(bus.native)
        } else {
          self.current_bus = Some(i64(args[0]))
        }
        [I32(count)]
      })
    }
    _ => raise @vm.UnknownImport("moonbitlang/async", name)
  }
}
