///|
fn main raise {
  let args = @env.args()
  let directory = args[1]
  @fs.create_dir(directory + "/nested")
  let path = directory + "/nested/data"
  @fs.write_bytes_to_file(path, b"\x00\xff\x42")
  assert_eq(@fs.read_file_to_bytes(path), b"\x00\xff\x42")
  assert_true(@fs.is_file(path))
  assert_true(@fs.is_dir(directory + "/nested"))
  @fs.remove_dir(directory + "/nested")
  println("files ok")
}
