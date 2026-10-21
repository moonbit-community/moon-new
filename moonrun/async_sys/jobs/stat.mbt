///|
// The packed metadata layout is shared with the guest async ABI.
pub fn packed_stat(
  fd : @sys.Fd,
  request : Int32,
  capacity : Int32,
) -> Bytes raise {
  let length = stat_length(request, capacity)
  let result = run_native_job(StatFd, "", fd, request, length, false)
  guard result.ret >= 0 else {
    raise @sys.OSError(result.errno, context="stat")
  }
  result.data
}
