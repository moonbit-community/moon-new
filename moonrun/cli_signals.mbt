///|
#external
priv type SignalRelay

///|
extern "C" fn open_signal_relay(fd : @sys.Fd) -> SignalRelay = "moonrun_cli_signal_open"

///|
extern "C" fn signal_relay_is_null(relay : SignalRelay) -> Bool = "moonrun_cli_signal_is_null"

///|
extern "C" fn take_signals(relay : SignalRelay) -> Int32 = "moonrun_cli_signal_take"

///|
extern "C" fn close_signal_relay(relay : SignalRelay) -> Unit = "moonrun_cli_signal_close"

///|
extern "C" fn terminate_by_signal(signal : Int32) -> Unit = "moonrun_native_terminate_process_by_signal"

///|
fn run_cli(
  program : @runtime.Module,
  args : Array[String],
  test_args : String?,
  policy : @runtime.Policy?,
  stack_size : Int64,
  no_stack_trace : Bool,
) -> @runtime.RunOutcome raise {
  let endpoints = FixedArray::make(2, @sys.invalid_fd())
  if create_signal_pipe(endpoints) < 0 {
    raise Failure("failed to create signal relay pipe")
  }
  defer ignore(@sys.close_fd(endpoints[0]))
  defer ignore(@sys.close_fd(endpoints[1]))
  let relay = open_signal_relay(endpoints[1])
  guard !signal_relay_is_null(relay) else {
    raise Failure("failed to initialize signal relay")
  }
  defer close_signal_relay(relay)
  let pending = Ref(0)
  let control = @runtime.RunControl(poll=() => {
    let buffer = FixedArray::make(64, b'\x00')
    ignore(read_signal_pipe(endpoints[0], buffer, buffer.length()))
    pending.val = pending.val | take_signals(relay)
    let signals = [@sys.Signal::SIGINT, SIGTERM, SIGHUP, SIGBREAK]
    for index in 0..<signals.length() {
      let bit = 1 << index
      if (pending.val & bit) != 0 {
        pending.val = pending.val & bit.lnot()
        return Some(signals[index].to_int())
      }
    }
    None
  })
  program.run(
    args~,
    test_args?,
    control~,
    policy?,
    stack_size~,
    no_stack_trace~,
  )
}

///|
#borrow(endpoints)
extern "C" fn create_signal_pipe(endpoints : FixedArray[@sys.Fd]) -> Int32 = "moonrun_cli_signal_pipe"

///|
#borrow(buffer)
extern "C" fn read_signal_pipe(
  fd : @sys.Fd,
  buffer : FixedArray[Byte],
  length : Int32,
) -> Int32 = "moonrun_cli_signal_read"
