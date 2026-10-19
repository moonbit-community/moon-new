///|
async fn main {
  if @async.platform is Windows {
    assert_eq(
      @process.run("cmd", [
        "/d", "/c", "start /b cmd /d /c \"ping -n 4 127.0.0.1 >nul\"",
      ]),
      0,
    )
  } else {
    assert_eq(@process.run("/bin/sh", ["-c", "sleep 3 & exit 0"]), 0)
    assert_eq(
      @process.run("/bin/sh", [
        "-c", "(sleep .1; printf 'descendant stdout\\n') & exit 0",
      ]),
      0,
    )
    @async.sleep(300)
  }
  println("direct child exited")
}
