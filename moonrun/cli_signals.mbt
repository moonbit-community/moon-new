///|
fn init {
  // The executable relays signals to the guest. The library leaves the
  // embedding application's existing native cancellation policy untouched.
  @signal.set_global_cancellation_signals([])
}

///|
#external
priv type SignalRelay

///|
extern "C" fn open_signal_relay(fd : @types.Fd) -> SignalRelay = "moonrun_cli_signal_open"

///|
extern "C" fn signal_relay_is_null(relay : SignalRelay) -> Bool = "moonrun_cli_signal_is_null"

///|
extern "C" fn take_signals(relay : SignalRelay) -> Int32 = "moonrun_cli_signal_take"

///|
extern "C" fn close_signal_relay(relay : SignalRelay) -> Unit = "moonrun_cli_signal_close"

///|
extern "C" fn terminate_by_signal(signal : Int32) -> Unit = "moonbitlang_async_terminate_process_by_signal"

///|
async fn run_cli(
  program : @runtime.Module,
  args : Array[String],
  test_args : String?,
  policy : @runtime.Policy?,
) -> @runtime.RunOutcome {
  let (read, write) = @pipe.pipe()
  defer read.close()
  let relay = open_signal_relay(write.fd())
  write.close()
  guard !signal_relay_is_null(relay) else {
    raise Failure("failed to initialize signal relay")
  }
  defer close_signal_relay(relay)
  @async.with_task_group(group => {
    let control = @runtime.RunControl()
    let run = group.spawn(() => {
      program.run(args~, test_args?, control~, policy?)
    })
    let monitor : @async.Task[Unit] = group.spawn(no_wait=true, () => {
      for ;; {
        ignore(read.read_exactly(1))
        let pending = take_signals(relay)
        let signals = [@signal.Signal::SIGINT, SIGTERM, SIGHUP, SIGBREAK]
        for index in 0..<signals.length() {
          if (pending & (1 << index)) != 0 {
            let signal = signals[index].to_int()
            if !control.send_signal(signal) {
              group.return_immediately(Signaled(signal))
            }
          }
        }
      }
    })
    let outcome = run.wait()
    monitor.cancel()
    outcome
  })
}
