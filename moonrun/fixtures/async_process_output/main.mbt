///|
async fn main {
  assert_eq(@process.run(@env.args()[1], ["--child-output"]), 0)
  println("output completed")
}
