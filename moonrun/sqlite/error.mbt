///|
/// Host ABI violations are distinct from SQLite's returned result codes.
pub(all) suberror SqliteError {
  InvalidHandle
  Fault
  Overflow
}
