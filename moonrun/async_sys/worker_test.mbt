///|
test "worker sleep uses a deadline rather than accumulating wakeup latency" {
  let completion = FixedArray::make(2, @async_sys.invalid_fd())
  assert_eq(pipe_endpoints(completion, false, false), 0)
  let reader = @async_sys.File::adopt(completion[0])
  defer reader.close()
  defer ignore(@async_sys.close_fd(completion[1]))
  let operation = @async_sys.sleep_job(1000)
  defer operation.close()
  let start = @async_sys.now()
  let worker = @async_sys.start_worker(
    operation.raw(),
    7,
    completion[1],
    null_bus(),
    0L,
    0L,
  )
  assert_false(worker.is_null())
  defer worker.close()
  let notification = FixedArray::make(4, b'\x00')
  assert_eq(reader.read(notification), 4)
  let elapsed = @async_sys.now() - start
  assert_eq(operation.ret(), 0)
  assert_true(elapsed >= 990L && elapsed < 1150L, msg="sleep took \{elapsed}ms")
}
