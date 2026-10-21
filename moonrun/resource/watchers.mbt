///|
pub(all) struct Watcher {
  fd : @sys.Fd
  files : Map[Int64, Int64]
}
