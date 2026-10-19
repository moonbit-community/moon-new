///|
async fn main {
  let args = @env.args()
  if args[1] == "child" {
    try {
      @fs.write_file(args[2], "must not be written")
      raise Failure("inherited policy was bypassed")
    } catch {
      @os_error.OSError(code, ..) if code is (5 | 13) => ()
      error => raise error
    }
    println("inherited policy enforced")
  } else {
    let (code, output, errors) = @process.collect_output(
      args[1],
      [args[2], "--policy", args[3], "--", "child", args[4]],
      extra_env={ "MOONRUN_INHERITED_POLICY": "invalid guest supplied value" },
    )
    guard code == 0 else {
      raise Failure("policy child exited \{code}: \{errors.text()}")
    }
    assert_eq(output.text(), "inherited policy enforced\n")
    assert_true(errors.text().contains("Sandbox policy blocked file write"))
    println("policy transfer passed")
  }
}
