///|
pub(all) struct Watcher {
  fd : @types.Fd
  files : Map[Int64, Int64]
}
