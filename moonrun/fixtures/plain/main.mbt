///|
fn main raise {
  println("Hello, MoonBit! 中文 😀")
  println(@env.args()[1:].join("|"))
  let bytes = b"\x00\xff\x42"
  assert_eq(bytes[1], b'\xff')
  println(bytes.to_unchecked_string())
  @sys.exit(17)
}

///|
test "pass" {
  assert_eq(1 + 1, 2)
}

///|
test "failure" {
  assert_eq(1, 2)
}

///|
test "continues after failure" {
  println("after failure")
}
