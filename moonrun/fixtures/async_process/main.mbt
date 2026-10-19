///|
async fn main {
  let windows = @async.platform is Windows
  let shell = if windows { "cmd" } else { "/bin/sh" }
  let args = if windows {
    ["/d", "/c", "echo %MOONRUN_CHILD_VALUE%&exit /b 23"]
  } else {
    ["-c", "printf '%s' \"$MOONRUN_CHILD_VALUE\"; exit 23"]
  }
  let (code, output, errors) = @process.collect_output(shell, args, extra_env={
    "MOONRUN_CHILD_VALUE": "child environment",
  })
  assert_eq(code, 23)
  assert_eq(output.text().trim().to_owned(), "child environment")
  assert_true(errors.binary().is_empty())
  @async.all(
    Array::makei(10, _ => {
      () => {
        let args = if windows {
          ["/d", "/c", "exit /b 0"]
        } else {
          ["-c", "exit 0"]
        }
        assert_eq(@process.run(shell, args), 0)
      }
    }),
  )
  |> ignore
  let directory = @fs.tmpdir(prefix="moonrun-process-")
  defer @fs.rmdir(directory, recursive=true) |> ignore
  let args = if windows {
    ["/d", "/c", "echo child>created"]
  } else {
    ["-c", "printf child > created"]
  }
  assert_eq(@process.run(shell, args, cwd=directory), 0)
  assert_eq(
    @fs.read_file(directory + "/created").text().trim().to_owned(),
    "child",
  )
  let args = if windows {
    ["/d", "/c", "ping -n 30 127.0.0.1 >nul"]
  } else {
    ["-c", "exec sleep 30"]
  }
  let pid = @async.with_task_group(group => {
    let child = @process.spawn(group, shell, args)
    child.cancel()
    child.pid
  })
  assert_true(pid > 0)
  if windows {
    assert_eq(
      @process.run(shell, [
        "/d", "/c", "echo child stdout&echo child stderr 1>&2",
      ]),
      0,
    )
  } else {
    assert_eq(
      @process.run(shell, [
        "-c", "printf 'child stdout\\n'; printf 'child stderr\\n' >&2",
      ]),
      0,
    )
  }
  println("async process passed")
}
