///|
async fn main {
  let input = @stdio.stdin.read_all()
  @stdio.stdout.write(input)
  @stdio.stderr.write("stderr\n")
}
