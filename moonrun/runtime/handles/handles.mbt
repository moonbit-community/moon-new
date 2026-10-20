///|
pub struct Handles {
  invalid_fd : Int64
  null_handle : Int64
  priv mut next : Int64
}

///|
pub fn Handles::Handles() -> Handles {
  { invalid_fd: 1L, null_handle: 2L, next: 3L, }
}

///|
pub fn Handles::allocate(self : Handles) -> Int64 {
  let handle = self.next
  self.next += 1L
  handle
}
