///|
test "Windows bare drive joins remain drive-relative without touching the drive" {
  if @async.platform is Windows {
    assert_eq(join_path("C:", "moon.pkg"), "C:moon.pkg")
  }
}
