///|
async fn main {
  if @env.args()[1] == "--child-output" {
    @stdio.stdout.write(Bytes::from_array(FixedArray::make(131072, b'x')))
    @stdio.stderr.write(Bytes::from_array(FixedArray::make(131072, b'y')))
    return
  }
  let program = @runtime.Module::load_file(@env.args()[1])
  if @env.args().get(2) == Some("process-output") {
    for _ in 0..<10 {
      let output : Array[Byte] = []
      let errors : Array[Byte] = []
      assert_eq(
        program.run(
          args=[@env.args()[0]],
          stdout=bytes => output.push_iter(bytes.iter()),
          stderr=bytes => errors.push_iter(bytes.iter()),
        ),
        Completed,
      )
      assert_eq(output.length(), 131072 + 17)
      assert_eq(
        Bytes::from_array(output[:131072]),
        Bytes::from_array(FixedArray::make(131072, b'x')),
      )
      assert_eq(Bytes::from_array(output[131072:]), b"output completed\n")
      assert_eq(
        Bytes::from_array(errors),
        Bytes::from_array(FixedArray::make(131072, b'y')),
      )
    }
    println("buffered child output survives run completion")
    return
  }
  if @env.args().get(2) == Some("process-exit") {
    let output : Array[Byte] = []
    let result = @async.with_timeout(1500, () => {
      program.run(stdout=bytes => output.push_iter(bytes.iter()), stderr=_ => ())
    })
    assert_eq(result, Completed)
    assert_eq(
      Bytes::from_array(output),
      if @async.platform is Windows {
        b"direct child exited\n"
      } else {
        b"descendant stdout\ndirect child exited\n"
      },
    )
    println("child exit is independent of descendant output EOF")
    return
  }
  if @env.args().get(2) == Some("orphan") {
    let directory = @fs.tmpdir(prefix="moonrun-orphan-")
    defer @fs.rmdir(directory, recursive=true) |> ignore
    let path = directory + "/result"
    assert_eq(program.run(args=[path]), Completed)
    @async.with_timeout(5000, () => {
      while !@fs.exists(path) {
        @async.sleep(10)
      }
    })
    assert_eq(@fs.read_file(path).text().trim().to_owned(), "orphan")
    println("orphan outlived embedded guest")
    return
  }
  if @env.args().get(2) == Some("cancel") {
    for _ in 0..<3 {
      check_cancellation(program)
    }
    println("embedded network cancellation passed")
    return
  }
  if @env.args().get(2) == Some("process-failure") {
    let reads = Ref(0)
    let output : Array[Byte] = []
    assert_eq(
      program.run(
        stdin=() => {
          reads.val += 1
          b""
        },
        stdout=bytes => output.push_iter(bytes.iter()),
      ),
      Completed,
    )
    assert_eq(reads.val, 0)
    assert_eq(Bytes::from_array(output), b"missing process rejected\n")
    println("failed spawn preserved embedding stdin")
    return
  }
  let network = @env.args().get(2) == Some("network")
  let process = @env.args().get(2) == Some("process")
  let run = () => {
    let input_sent = Ref(false)
    let output : Array[Byte] = []
    let errors : Array[Byte] = []
    let outcome = program.run(
      stdin=() => {
        if input_sent.val {
          b""
        } else {
          input_sent.val = true
          b"hello\x00world\xff"
        }
      },
      stdout=bytes => output.push_iter(bytes.iter()),
      stderr=bytes => errors.push_iter(bytes.iter()),
    )
    assert_eq(outcome, Completed)
    assert_eq(
      Bytes::from_array(output),
      if process {
        if @async.platform is Windows {
          b"child stdout\r\nasync process passed\n"
        } else {
          b"child stdout\nasync process passed\n"
        }
      } else if network {
        b"async TCP and UDP passed\n"
      } else {
        b"hello\x00world\xff"
      },
    )
    assert_eq(
      Bytes::from_array(errors),
      if process {
        if @async.platform is Windows {
          b"child stderr\r\n"
        } else {
          b"child stderr\n"
        }
      } else if network {
        b""
      } else {
        b"stderr\n"
      },
    )
  }
  @async.all([run, run]) |> ignore
  println(
    if process {
      "embedded async process passed"
    } else if network {
      "embedded async networking passed"
    } else {
      "embedded async stdio passed"
    },
  )
}

///|
async fn check_cancellation(program : @runtime.Module) -> Unit {
  let output : Array[Byte] = []
  let started = @cond_var.Cond()
  @async.with_timeout(10_000, () => {
    @async.with_task_group(group => {
      let run = group.spawn(() => {
        program.run(stdout=bytes => {
          output.push_iter(bytes.iter())
          started.signal()
        })
      })
      while !output.contains(b'\n') {
        started.wait()
      }
      // Allow the guest to enter its pending accept before cancelling it.
      @async.sleep(20)
      run.cancel()
      try {
        ignore(run.wait())
        raise Failure("guest returned before cancellation")
      } catch {
        @async.WaitedTaskAlreadyCancelled => ()
        error => raise error
      }
    })
  })
  let address = @socket.Addr::parse(
    @utf8.decode(Bytes::from_array(output)).trim().to_owned(),
  )
  try {
    let connection = @socket.Tcp::connect(address)
    connection.close()
    raise Failure("cancelled guest left its listener open")
  } catch {
    @os_error.OSError(_, ..) as error if error.is_ECONNREFUSED() => ()
    error => raise error
  }
}
