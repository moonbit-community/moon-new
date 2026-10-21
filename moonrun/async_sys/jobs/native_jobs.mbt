///|
pub(all) enum NativeJobKind {
  StatPath = 1
  ReadDirectory = 2
  StatFd = 3
  ResolveHost = 4
  AddWatch = 5
  OpenWatcher = 6
  ReadWatchEvents = 7
  ReadPolicy = 8
}

///|
fn NativeJobKind::to_int(self : NativeJobKind) -> Int32 = "%identity"

///|
pub fn stat_length(request : Int32, capacity : Int32) -> Int32 raise {
  let mut length = 8
  for bit in 0..<8 {
    if (request & (1 << bit)) != 0 {
      length += if bit < 4 { 8 } else { 16 }
    }
  }
  guard request >= 0 && request <= 255 && capacity >= length else {
    raise @sys.OSError(
      if @sys.platform is Windows {
        87
      } else {
        22
      },
      context="stat request",
    )
  }
  length
}

///|
pub fn make_native_job(
  operation : NativeJobKind,
  path : String,
  parent : @sys.Fd,
  request : Int32,
  capacity : Int32,
  follow : Bool,
) -> @resource.Task raise {
  guard capacity >= 0 else {
    raise @sys.OSError(
      if @sys.platform is Windows {
        87
      } else {
        22
      },
      context="filesystem job",
    )
  }
  let path = @sys.os_path(path)
  let native = metadata_operation(
    operation.to_int(),
    path,
    path.length(),
    parent,
    request,
    capacity,
    follow,
  )
  @resource.Task(native, publish=() => {
    let result = @resource.result(native)
    if result.ret >= 0 && operation is OpenWatcher {
      result.opened = Some(
        @resource.Resource(Watcher({ fd: native.take_fd(), files: Map([]), })),
      )
    }
    result
  })
}

///|
pub fn run_native_job(
  operation : NativeJobKind,
  path : String,
  parent : @sys.Fd,
  request : Int32,
  capacity : Int32,
  follow : Bool,
) -> @resource.JobResult raise {
  make_native_job(operation, path, parent, request, capacity, follow).run()
}

///|
#borrow(path)
extern "C" fn metadata_operation(
  operation : Int32,
  path : Bytes,
  length : Int32,
  parent : @sys.Fd,
  request : Int32,
  capacity : Int32,
  follow : Bool,
) -> @sys.Operation = "moonrun_operation_metadata"
