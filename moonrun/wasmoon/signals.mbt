///|
fn Context::signal_import(
  self : Context,
  caller : @vm.Caller,
  name : String,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.async_host
  match name {
    "signal/get_signal_by_index" => {
      let signal = match i32(args[0]) {
        0 => @sys.Signal::SIGINT
        1 => @sys.Signal::SIGTERM
        2 => @sys.Signal::SIGHUP
        3 => @sys.Signal::SIGBREAK
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
      host.signals.clear()
      for index in 0..<length {
        let signal = memory.load_i32_at(pointer + index.to_int64() * 4L)
        if signal >= 0 {
          host.signals.add(signal)
        }
      }
      []
    }
    "signal/start_signal_handler" => {
      host.signal_enabled = true
      []
    }
    "signal/terminate_signal_handler" => {
      host.signal_enabled = false
      []
    }
    "signal/set_console_control_handler" => {
      host.signal_enabled = i32(args[0]) != 0
      [I32(1)]
    }
    _ => raise @vm.UnknownImport("moonbitlang/async", name)
  }
}

///|
fn Context::legacy_signal_job(
  self : Context,
  caller : @vm.Caller,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let host = self.runtime.async_host
  let count = i32(args[1])
  guard count >= 0 && count <= 0x3FFF_FFFF else {
    raise @vm.OutOfBoundsMemoryAccess
  }
  let bytes = guest_bytes(caller, i32(args[0]), count * 4).to_fixedarray()
  let interests = Set([])
  for index in 0..<count {
    interests.add(@sys.buffer_word(bytes, index * 4, 4).to_int())
  }
  let key = self.runtime.handles.allocate()
  [
    I64(
      host.new_job(() => {
        let pipes = FixedArray::make(2, @sys.invalid_native_fd())
        if @sys.create_guest_pipe(pipes, false, true) < 0 {
          @sys.check_errno("signal waiter")
        }
        let waiter : @async_host.SignalWaiter = {
          interests,
          write: pipes[1],
          signal: None,
        }
        host.signal_waiters[key] = waiter
        let operation = @sys.read_job(pipes[0], 4, -1L)
        @resource.Task(
          operation,
          publish=() => {
            let result = @resource.result(operation)
            {
              ..result,
              ret: if result.ret == 4 {
                @sys.buffer_word(result.data.to_fixedarray(), 0, 4).to_int()
              } else {
                result.ret
              },
            }
          },
          cleanup=() => {
            host.signal_waiters.remove(key)
            ignore(@sys.close_guest_pipe(pipes[0]))
            ignore(@sys.close_guest_pipe(pipes[1]))
          },
        )
      }),
    ),
  ]
}
