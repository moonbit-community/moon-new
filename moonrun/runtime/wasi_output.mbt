///|
fn Host::wasi_write(
  self : Host,
  context : @wasi.WasiContext,
  caller : @vm.Caller,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise @vm.RuntimeError {
  let fd = i32(args[0])
  let iovs = i32(args[1])
  let count = i32(args[2])
  let result = i32(args[3])
  let memory = guest_memory(caller)
  let (slot, open) = if fd == context.stdout_fd {
    (1, context.stdout_open)
  } else if fd == context.stderr_fd {
    (2, context.stderr_open)
  } else {
    return [I32(@wasi.fd_write(context, memory, fd, iovs, count, result))]
  }
  if !open {
    return [I32(@wasi.Errno::Badf.to_i32())]
  }
  if (context.stdio_rights[slot].0 & @wasi.right_fd_write) == 0L {
    return [I32(@wasi.Errno::NotCapable.to_i32())]
  }
  let ranges = wasi_iovecs(memory, iovs, count, result) catch {
    @vm.OutOfBoundsMemoryAccess => return [I32(@wasi.Errno::Fault.to_i32())]
    error => raise error
  }
  self.suspend(() => {
    let mut written = 0L
    try {
      for (offset, size) in ranges {
        let mut sent = 0
        while sent < size {
          let length = Int32::min(size - sent, 65536)
          let bytes = memory.read_bytes(
            (offset + sent.to_int64()).to_int(),
            length,
          )
          self.output(slot, bytes)
          written += length.to_int64()
          sent += length
        }
      }
    } catch {
      @os_error.OSError(_, ..) =>
        if written == 0L {
          return [I32(@wasi.Errno::IO.to_i32())]
        }
      error => raise error
    }
    memory.store_i32(result, written.to_int())
    [I32(0)]
  })
}
