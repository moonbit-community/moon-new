///|
async fn main {
  try {
    ignore(@process.run("moonrun-missing-executable-0a7483e1", []))
    raise Failure("missing executable unexpectedly started")
  } catch {
    @os_error.OSError(_, ..) as error if error.is_ENOENT() => ()
    error => raise error
  }
  println("missing process rejected")
}
