///|
async fn main {
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      @async.sleep(20)
      @stdio.stdout.write("later\n")
    })
    @async.sleep(1)
    @stdio.stdout.write("earlier\n")
  })
}
