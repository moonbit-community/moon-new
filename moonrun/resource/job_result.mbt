///|
pub(all) struct JobResult {
  ret : Int32
  errno : Int32
  data : Bytes
  mut opened : Resource?
}
