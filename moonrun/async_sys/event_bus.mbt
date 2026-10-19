///|
#external
pub type NativeEventBus

///|
pub extern "C" fn create_event_bus(fd : @types.Fd) -> NativeEventBus = "moonrun_event_bus_create"

///|
pub extern "C" fn event_bus_is_null(bus : NativeEventBus) -> Bool = "moonrun_event_bus_is_null"

///|
pub extern "C" fn close_event_bus(bus : NativeEventBus) -> Unit = "moonrun_event_bus_close"

///|
pub extern "C" fn begin_event_wait(
  bus : NativeEventBus,
  timeout : Int32,
) -> Unit = "moonrun_event_bus_begin"

///|
pub extern "C" fn event_wait_result(bus : NativeEventBus) -> Int32 = "moonrun_event_bus_result"

///|
pub extern "C" fn event_wait_errno(bus : NativeEventBus) -> Int32 = "moonrun_event_bus_errno"

///|
pub extern "C" fn register_event_fd(
  bus : NativeEventBus,
  fd : @types.Fd,
  read_only : Bool,
  key : Int64,
) -> Int32 = "moonrun_event_bus_register"

///|
pub extern "C" fn event_fd(bus : NativeEventBus, index : Int32) -> Int64 = "moonrun_event_bus_event_fd"

///|
pub extern "C" fn event_flags(bus : NativeEventBus, index : Int32) -> Int32 = "moonrun_event_bus_event_flags"

///|
pub extern "C" fn event_bytes(bus : NativeEventBus, index : Int32) -> Int32 = "moonrun_event_bus_event_bytes"

///|
pub extern "C" fn event_token(bus : NativeEventBus, index : Int32) -> Int64 = "moonrun_event_bus_event_token"

///|
pub extern "C" fn event_pid(bus : NativeEventBus, index : Int32) -> Int32 = "moonrun_event_bus_event_pid"

///|
pub extern "C" fn register_completion_fd(
  bus : NativeEventBus,
  fd : @types.Fd,
  key : Int64,
) -> Int32 = "moonrun_event_bus_register_completion"

///|
pub extern "C" fn post_completion(
  bus : NativeEventBus,
  key : Int64,
  token : Int64,
  bytes : Int32,
) -> Int32 = "moonrun_event_bus_post"

///|
pub struct EventBus {
  native : NativeEventBus
  read : @pipe.PipeRead
  mut closed : Bool
  registered : Set[Int64]
}

///|
pub fn EventBus::new() -> EventBus raise {
  let (read, write) = @pipe.pipe()
  errdefer read.close()
  defer write.close()
  let native = create_event_bus(write.fd())
  guard !event_bus_is_null(native) else {
    raise Operation("failed to create guest event bus")
  }
  { native, read, closed: false, registered: Set([]), }
}

///|
pub fn EventBus::close(self : EventBus) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  // Stop and join the C worker before releasing the notification reader.
  close_event_bus(self.native)
  self.read.close()
}

///|
pub async fn EventBus::wait(self : EventBus, timeout : Int32) -> Int32 {
  begin_event_wait(self.native, timeout)
  // Only this task accesses the pipe. Cancellation unwinds to @wasmoon.Context::close,
  // which wakes the native wait and joins it without accessing the MoonBit heap.
  ignore(self.read.read_exactly(1))
  event_wait_result(self.native)
}
