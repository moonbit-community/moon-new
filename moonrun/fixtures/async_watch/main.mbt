///|
async fn main {
  let directory = @fs.tmpdir(prefix="moonrun-watch-")
  defer @fs.rmdir(directory, recursive=true) |> ignore
  let watcher = @fs.Watcher(
    directory,
    report_event_on_init=false,
    debounce_timeout=10,
  )
  defer watcher.close()
  @async.with_timeout(10_000, () => {
    @async.with_task_group(group => {
      let changed = group.spawn(() => watcher.wait())
      @async.sleep(20)
      @fs.write_file(directory + "/watched", "created")
      assert_false(changed.wait().is_empty())
    })
  })
  println("async filesystem watcher passed")
}
