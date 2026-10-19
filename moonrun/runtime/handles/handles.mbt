///|
pub struct Handles {
  priv mut next : Int64
}

///|
pub fn Handles::Handles() -> Handles {
  { next: 1L, }
}

///|
pub fn Handles::allocate(self : Handles) -> Int64 {
  let handle = self.next
  self.next += 1L
  handle
}
