///|
// Reuse native async's descriptor-stat ABI on the C-owned worker.
pub async fn packed_stat(
  fd : @types.Fd,
  request : Int32,
  capacity : Int32,
) -> Bytes {
  let length = stat_length(request, capacity)
  let result = run_native_job(StatFd, "", fd, request, length, false)
  guard result.ret >= 0 else {
    raise @os_error.OSError(result.errno, context="stat")
  }
  result.data
}
