///|
pub fn read_directory(
  fd : @resource.Resource,
  buffer : FixedArray[Byte],
  length : Int32,
  restart : Bool,
) -> @resource.Task raise {
  let operation = match fd.owner {
    File(file) => file.prepare_directory(length, restart)
    _ => @sys.directory_job(fd.native(), length, restart)
  }
  @resource.Task(operation, publish=() => {
    let result = @resource.result(operation)
    if result.ret >= 0 {
      result.data.to_fixedarray().blit_to(buffer, len=length)
    }
    result
  })
}
