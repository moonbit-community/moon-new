///|
pub async fn read_directory(
  fd : @resource.Resource,
  buffer : FixedArray[Byte],
  length : Int32,
  restart : Bool,
) -> @resource.JobResult {
  fd.cursor_lock.acquire()
  defer fd.cursor_lock.release()
  let result = @native_jobs.run_native_job(
    ReadDirectory,
    "",
    fd.native(),
    0,
    length,
    restart,
  )
  if result.ret >= 0 {
    result.data.to_fixedarray().blit_to(buffer, len=length)
  }
  result
}
