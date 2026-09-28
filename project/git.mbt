///|
async fn initialize_git(
  destination : String,
  warnings : Array[String],
) -> (String, String) {
  try {
    if @repository.initialize(destination) {
      ("Initialized empty Git repository in \{destination}/.git/\n", "")
    } else {
      ("", "")
    }
  } catch {
    error => {
      warnings.push("Git initialization failed: \{error}")
      ("", "")
    }
  }
}
