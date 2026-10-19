///|
fn guest_memory(caller : @vm.Caller) -> @vm.Memory raise @vm.RuntimeError {
  guard caller.instance.mem_addrs.get(0) is Some(address) else {
    raise @vm.OutOfBoundsMemoryAccess
  }
  caller.store.get_mem(address)
}

///|
fn wasi_iovecs(
  memory : @vm.Memory,
  pointer : Int32,
  count : Int32,
  result : Int32,
) -> Array[(Int64, Int32)] raise @vm.RuntimeError {
  let base = pointer.reinterpret_as_uint().to_int64()
  let output = result.reinterpret_as_uint().to_int64()
  let length = memory.byte_len()
  guard count >= 0 &&
    base + count.to_int64() * 8L <= length &&
    output + 4L <= length else {
    raise @vm.OutOfBoundsMemoryAccess
  }
  let ranges = []
  for index in 0..<count {
    let entry = base + index.to_int64() * 8L
    let offset = memory.load_i32_at(entry).reinterpret_as_uint().to_int64()
    let size = memory.load_i32_at(entry + 4L)
    guard size >= 0 && offset + size.to_int64() <= length else {
      raise @vm.OutOfBoundsMemoryAccess
    }
    ranges.push((offset, size))
  }
  ranges
}

///|
fn Context::wasi_read(
  self : Context,
  context : @wasi.WasiContext,
  caller : @vm.Caller,
  args : Array[@wasm.Value],
) -> Array[@wasm.Value] raise {
  let fd = i32(args[0])
  let iovs = i32(args[1])
  let count = i32(args[2])
  let result = i32(args[3])
  let memory = guest_memory(caller)
  if fd != context.stdin_fd {
    return [I32(@wasi.fd_read(context, memory, fd, iovs, count, result))]
  }
  if !context.stdin_open {
    return [I32(@wasi.Errno::Badf.to_i32())]
  }
  if (context.stdio_rights[0].0 & @wasi.right_fd_read) == 0L {
    return [I32(@wasi.Errno::NotCapable.to_i32())]
  }
  let ranges = wasi_iovecs(memory, iovs, count, result) catch {
    @vm.OutOfBoundsMemoryAccess => return [I32(@wasi.Errno::Fault.to_i32())]
    error => raise error
  }
  let requested = ranges.fold(init=0L, (total, range) => {
    total + range.1.to_int64()
  })
  self.suspend(() => {
    if requested == 0L {
      memory.store_i32(result, 0)
      return [I32(0)]
    }
    let data = self.runtime.stdio.read_chunk(
      @cmp.minimum(requested, 0x7FFF_FFFFL).to_int(),
    ) catch {
      @os_error.OSError(_, ..) => return [I32(@wasi.Errno::IO.to_i32())]
      error => raise error
    }
    let mut read = 0
    for (offset, size) in ranges {
      let bytes = @cmp.minimum(data.length() - read, size)
      memory.init_data_at(offset, data[read:read + bytes].to_owned())
      read += bytes
      if bytes < size {
        break
      }
    }
    memory.store_i32(result, read)
    [I32(0)]
  })
}
