///|
pub(all) enum Signal {
  SIGINT
  SIGTERM
  SIGHUP
  SIGBREAK
}

///|
pub fn Signal::to_int(self : Signal) -> Int32 {
  match (platform, self) {
    (Windows, SIGINT) => 0
    (Windows, SIGHUP) => 2
    (Windows, SIGBREAK) => 1
    (Windows, SIGTERM) => -1
    (_, SIGINT) => 2
    (_, SIGTERM) => 15
    (_, SIGHUP) => 1
    _ => -1
  }
}
