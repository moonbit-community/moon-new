///|
async test "character devices support sequential guest I/O" {
  if @async.platform is Windows {
    return
  }
  let resource = @resource.Resource(File(@fs.open("/dev/null", mode=ReadWrite)))
  defer resource.release()
  assert_eq(resource.write_job(b"abc", -1L).ret, 3)
  let result = resource.read_job(16, -1L)
  assert_eq(result.ret, 0)
  assert_eq(result.data, b"")
}
