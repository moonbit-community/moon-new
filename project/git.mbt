///|
async fn initialize_git(
  destination : String,
  warnings : Array[String],
) -> (String, String) {
  try {
    let (status, _, _) = @process.collect_output(
      "git",
      ["rev-parse", "--is-inside-work-tree"],
      cwd=destination,
    )
    if status == 0 {
      return ("", "")
    }
    let (status, stdout, stderr) = @process.collect_output(
      "git",
      ["init"],
      cwd=destination,
    )
    if status != 0 {
      warnings.push(
        "Git initialization failed (exit \{status}): \{stderr.text()}",
      )
      ("", "")
    } else {
      (stdout.text(), stderr.text())
    }
  } catch {
    error => {
      warnings.push(
        "Could not check or initialize Git; is git available? \{error}",
      )
      ("", "")
    }
  }
}
