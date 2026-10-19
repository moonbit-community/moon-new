///|
pub fn invokes_moonx(command : String) -> Bool {
  let program = if @async.platform is Windows {
    let output = StringBuilder()
    let mut quoted = false
    for c in command {
      if c == '"' {
        quoted = !quoted
      } else if !quoted && c is (' ' | '\t') {
        break
      } else {
        output.write_char(c)
      }
    }
    ascii_lower(output.to_string())
  } else {
    command
  }
  let basename = @path.Path(program).basename()
  basename is ("moonx" | "moonx.exe")
}

///|
/// Consume an inherited native policy descriptor. The caller transfers ownership
/// of this descriptor and must remove its environment marker before provisioning
/// the guest environment. Invalid transfers fail without running the guest.
pub async fn Policy::from_inherited_handle(token : String) -> Policy {
  let token = @string.parse_uint64(token)
  let fd = @sys.adopt_policy_fd(token)
  if fd == @sys.invalid_native_fd() {
    @os_error.check_errno("inherited policy handle")
  }
  defer ignore(@sys.close_guest_pipe(fd))
  let result = @native_jobs.run_native_job(ReadPolicy, "", fd, 0, 0, false)
  if result.ret < 0 {
    raise @os_error.OSError(result.errno, context="inherited policy read")
  }
  Policy::from_json(@utf8.decode(result.data))
}
