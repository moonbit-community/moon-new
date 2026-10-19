///|
pub async fn Stdio::deny(
  self : Stdio,
  action : String,
  target~ : String = "",
) -> Unit {
  self.output(
    2,
    @utf8.encode(
      "Sandbox policy blocked \{action}" +
      (if target.is_empty() { "" } else { ": \{target}" }) +
      "\n",
    ),
  )
  raise @os_error.OSError(
    if @async.platform is Windows {
      5
    } else {
      13
    },
    context="sandbox policy",
  )
}
