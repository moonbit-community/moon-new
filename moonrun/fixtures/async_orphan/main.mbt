///|
async fn main {
  let windows = @async.platform is Windows
  let shell = if windows { "cmd" } else { "/bin/sh" }
  let args = if windows {
    [
      "/d", "/c", "ping -n 2 127.0.0.1 >nul &echo orphan >\"%MOONRUN_ORPHAN_TARGET%\"",
    ]
  } else {
    ["-c", "sleep 0.1; printf orphan >\"$MOONRUN_ORPHAN_TARGET\""]
  }
  let pid = @process.spawn_orphan(shell, args, extra_env={
    "MOONRUN_ORPHAN_TARGET": @env.args()[1],
  })
  assert_true(pid > 0)
}
