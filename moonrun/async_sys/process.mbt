///|
#external
pub type NativeChild

///|
pub extern "C" fn initialize_child_signals() -> Unit = "moonrun_child_init"

///|
fn init {
  // Capture before async installs its host signal mask. @process.Child processes inherit
  // the caller's ambient mask rather than the event loop's private one.
  initialize_child_signals()
}

///|
#borrow(input, policy)
pub extern "C" fn start_child(
  input : Bytes,
  length : Int32,
  argc : Int32,
  envc : Int32,
  stdin : @types.Fd,
  stdout : @types.Fd,
  stderr : @types.Fd,
  orphan : Bool,
  no_console : Bool,
  notify : @types.Fd,
  policy : Bytes,
  policy_length : Int32,
) -> NativeChild = "moonrun_child_start"

///|
pub extern "C" fn child_is_null(child : NativeChild) -> Bool = "moonrun_child_is_null"

///|
pub extern "C" fn child_pid(child : NativeChild) -> Int32 = "moonrun_child_pid"

///|
pub extern "C" fn child_error(child : NativeChild) -> Int32 = "moonrun_child_error"

///|
pub extern "C" fn child_status(child : NativeChild) -> Int32 = "moonrun_child_status"

///|
pub extern "C" fn child_handle(child : NativeChild) -> @types.Fd = "moonrun_child_handle"

///|
pub extern "C" fn child_signal(child : NativeChild, signal : Int32) -> Unit = "moonrun_child_signal"

///|
pub extern "C" fn join_child(child : NativeChild) -> Unit = "moonrun_child_join"

///|
pub extern "C" fn free_child(child : NativeChild) -> Unit = "moonrun_child_free"

///|
pub extern "C" fn open_native_process(pid : Int32) -> @types.Fd = "moonbitlang_async_open_pid_handle"

///|
#borrow(result)
pub extern "C" fn native_process_result(
  handle : @types.Fd,
  pid : Int32,
  result : Ref[Int32],
) -> Int32 = "moonbitlang_async_get_process_result"

///|
pub extern "C" fn native_process_fd_valid(handle : @types.Fd) -> Bool = "moonrun_process_fd_valid"

///|
pub extern "C" fn native_process_ready(handle : @types.Fd) -> Int32 = "moonrun_process_ready"

///|
pub extern "C" fn signal_process_pid(pid : Int32, signal : Int32) -> Unit = "moonrun_signal_process_pid"

///|
pub extern "C" fn buffered_pipe_bytes(fd : @types.Fd) -> Int32 = "moonrun_buffered_pipe_bytes"

///|
#borrow(left, right)
pub extern "C" fn environment_key_equal(
  left : String,
  left_len : Int32,
  right : String,
  right_len : Int32,
) -> Bool = "moonrun_environment_key_equal"

///|
pub extern "C" fn register_child_pid(
  bus : NativeEventBus,
  pid : Int32,
) -> Int32 = "moonrun_event_bus_register_pid"
