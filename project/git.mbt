///|
async fn initialize_git(destination : String, warnings : Array[String]) -> Bool {
  @repository.initialize(destination) catch {
    error => {
      warnings.push("Git initialization failed: \{error}")
      false
    }
  }
}
