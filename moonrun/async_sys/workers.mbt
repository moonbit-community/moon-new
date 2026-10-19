///|
pub extern "C" fn signal_completion(fd : @types.Fd) -> Int32 = "moonrun_completion_signal"

///|
pub extern "C" fn drain_completion(fd : @types.Fd) -> Int32 = "moonrun_completion_drain"
