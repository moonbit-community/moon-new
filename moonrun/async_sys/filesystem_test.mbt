///|
test "synchronous native filesystem and owned worker results" {
  let path = @async_sys.tmpdir(prefix="moonrun-native-test-")
  defer @async_sys.rmdir(path, recursive=true)
  @async_sys.write_file(path + "/hello", b"hello")
  assert_eq(@async_sys.read_file(path + "/hello"), b"hello")
  assert_true(@async_sys.kind(path) is Directory)
  assert_true(@async_sys.kind(path + "/hello") is Regular)
  assert_eq(@async_sys.readdir(path), ["hello"])
}

///|
#borrow(endpoints)
extern "C" fn pipe_endpoints(
  endpoints : FixedArray[@async_sys.Fd],
  read_async : Bool,
  write_async : Bool,
) -> Int32 = "moonrun_create_pipe"

///|
extern "C" fn null_bus() -> @async_sys.NativeEventBus = "moonrun_event_bus_null"

///|
test "native workers publish owned read buffers before completion and acknowledge cancellation" {
  let endpoints = FixedArray::make(2, @async_sys.invalid_fd())
  assert_eq(pipe_endpoints(endpoints, false, false), 0)
  let reader = @async_sys.File::adopt(endpoints[0])
  let writer = @async_sys.File::adopt(endpoints[1])
  defer reader.close()
  defer writer.close()
  let completion = FixedArray::make(2, @async_sys.invalid_fd())
  assert_eq(pipe_endpoints(completion, false, false), 0)
  let completed = @async_sys.File::adopt(completion[0])
  defer completed.close()
  defer ignore(@async_sys.close_fd(completion[1]))
  for index in 0..<20 {
    let operation = @async_sys.read_job(endpoints[0], 4, -1L)
    defer operation.close()
    let worker = @async_sys.start_worker(
      operation.raw(),
      index,
      completion[1],
      null_bus(),
      0L,
      0L,
    )
    assert_false(worker.is_null())
    defer worker.close()
    assert_eq(writer.write_once(b"test"), 4)
    let notification = FixedArray::make(4, b'\x00')
    assert_eq(completed.read(notification), 4)
    assert_true(worker.done())
    assert_eq(notification[0].to_int(), index)
    assert_eq(operation.buffer(), b"test")
  }
  // Cancellation may arrive before the new thread has initialized its TLS.
  for _ in 0..<100 {
    let operation = @async_sys.read_job(endpoints[0], 4, -1L)
    defer operation.close()
    let worker = @async_sys.start_worker(
      operation.raw(),
      99,
      @async_sys.invalid_fd(),
      null_bus(),
      0L,
      0L,
    )
    assert_false(worker.is_null())
    worker.close()
    assert_eq(operation.ret(), -1)
    assert_true(
      @async_sys.OSError(operation.error(), context="cancelled read").is_EINTR() ||
      @async_sys.platform is Windows,
    )
  }
}

///|
test "pipe EOF is distinct from temporarily empty and buffered output" {
  let endpoints = FixedArray::make(2, @async_sys.invalid_fd())
  assert_eq(pipe_endpoints(endpoints, false, false), 0)
  let reader = @async_sys.File::adopt(endpoints[0])
  let writer = @async_sys.File::adopt(endpoints[1])
  defer reader.close()
  defer writer.close()
  assert_false(@async_sys.pipe_eof(endpoints[0]))
  assert_eq(writer.write_once(b"x"), 1)
  writer.close()
  assert_false(@async_sys.pipe_eof(endpoints[0]))
  let buffer = FixedArray::make(1, b'\x00')
  assert_eq(reader.read(buffer), 1)
  assert_true(@async_sys.pipe_eof(endpoints[0]))
}

///|
test "positioned I/O preserves the sequential file cursor" {
  let directory = @async_sys.tmpdir(prefix="moonrun-position-")
  defer @async_sys.rmdir(directory, recursive=true)
  let path = directory + "/file"
  @async_sys.write_file(path, b"abcdef")
  let file = @async_sys.open(path, mode=ReadWrite)
  defer file.close()
  let positioned = file.prepare_read(2, 3L)
  defer positioned.close()
  positioned.run()
  assert_eq(positioned.buffer(), b"de")
  let buffer = FixedArray::make(2, b'\x00')
  assert_eq(file.read(buffer), 2)
  assert_eq(Bytes::from_array(buffer), b"ab")
  let write = file.prepare_write(b"XY", 4L)
  defer write.close()
  write.run()
  assert_eq(write.ret(), 2)
  assert_eq(file.read(buffer), 2)
  assert_eq(Bytes::from_array(buffer), b"cd")
  assert_eq(@async_sys.read_file(path), b"abcdXY")
}

///|
test "Unix worker writes resume after pipe backpressure" {
  if @async_sys.platform is Windows {
    return
  }
  let endpoints = FixedArray::make(2, @async_sys.invalid_fd())
  assert_eq(pipe_endpoints(endpoints, true, true), 0)
  defer ignore(@async_sys.close_fd(endpoints[0]))
  defer ignore(@async_sys.close_fd(endpoints[1]))
  let buffer = FixedArray::make(4096, b'x')
  let mut buffered = 0
  for ;; {
    let count = @async_sys.write_guest_pipe(
      endpoints[1],
      buffer,
      buffer.length(),
    )
    if count < 0 {
      assert_true(
        @async_sys.OSError(@async_sys.get_errno(), context="fill pipe").is_nonblocking_io_error(),
      )
      break
    }
    buffered += count
  }
  assert_true(buffered > 0)
  let operation = @async_sys.write_job(endpoints[1], b"z", -1L)
  defer operation.close()
  let worker = @async_sys.start_worker(
    operation.raw(),
    7,
    @async_sys.invalid_fd(),
    null_bus(),
    0L,
    0L,
  )
  defer worker.close()
  // Let the worker observe EAGAIN before making room for its write.
  @async_sys.sleep(10)
  let mut drained = 0
  while drained < buffered {
    let count = @async_sys.read_guest_pipe(
      endpoints[0],
      buffer,
      @cmp.minimum(buffer.length(), buffered - drained),
    )
    assert_true(count > 0)
    drained += count
  }
  let deadline = @async_sys.now() + 2000L
  while !worker.poll() && @async_sys.now() < deadline {
    @async_sys.sleep(1)
  }
  assert_true(worker.done())
  assert_eq(operation.ret(), 1)
  assert_eq(@async_sys.read_guest_pipe(endpoints[0], buffer, 1), 1)
  assert_eq(buffer[0], b'z')
}
