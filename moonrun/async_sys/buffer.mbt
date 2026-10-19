///|
pub fn check_range(
  start : Int32,
  length : Int32,
  size : Int32,
) -> Unit raise HostError {
  guard start >= 0 && length >= 0 && start <= size && length <= size - start else {
    raise Bounds
  }
}
