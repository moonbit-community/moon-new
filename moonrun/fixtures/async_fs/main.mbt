///|
async fn main {
  let directory = @env.args()[1]
  let file = directory + "/hello"
  @fs.write_file(file, b"hello\x00world\xff")
  let data = @fs.read_file(file).binary()
  assert_eq(data, b"hello\x00world\xff")
  assert_eq(@fs.file_size(file), 12L)
  assert_eq(@fs.kind(file), Regular)
  assert_eq(@fs.readdir(directory), ["hello"])
  @fs.rename(file, directory + "/renamed")
  @fs.remove(directory + "/renamed")
  @stdio.stdout.write("async filesystem passed\n")
}
