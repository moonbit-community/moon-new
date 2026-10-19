///|
#external
priv type NativeJob

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
    raise @os_error.OSError(
      if @async.platform is Windows {
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
pub async fn run_native_job(
  operation : NativeJobKind,
  path : String,
  parent : @types.Fd,
  request : Int32,
  capacity : Int32,
  follow : Bool,
) -> @resource.JobResult {
  guard !path.contains_char('\u0000') && capacity >= 0 else {
    raise @os_error.OSError(
      if @async.platform is Windows {
        87
      } else {
        22
      },
      context="filesystem job",
    )
  }
  let path = if @async.platform is Windows {
    @utf16.encode(path, endianness=Little, bom=false)
  } else {
    @utf8.encode(path)
  }
  let (read, write) = @pipe.pipe()
  defer read.close()
  let job = start_native_job(
    operation.to_int(),
    path,
    path.length(),
    parent,
    request,
    capacity,
    follow,
    write.fd(),
  )
  let error = @os_error.get_errno()
  write.close()
  guard !native_job_is_null(job) else {
    raise @os_error.OSError(error, context="native worker startup")
  }
  let mut joined = false
  defer (if !joined && operation is ResolveHost {
    detach_native_job(job)
  } else {
    free_native_job(job)
  })
  defer (if !joined && operation is ReadWatchEvents {
    cancel_native_job(job)
    @async.protect_from_cancel(() => {
      ignore(read.read_exactly(1))
      join_native_job(job)
      joined = true
    })
  })
  let wait : async () -> @resource.JobResult = () => {
    ignore(read.read_exactly(1))
    join_native_job(job)
    joined = true
    let ret = native_job_result(job)
    {
      ret,
      errno: native_job_error(job),
      data: native_job_buffer(job),
      opened: if ret >= 0 && operation is OpenWatcher {
        Some(
          @resource.Resource(
            @resource.Watcher({ fd: native_job_take_fd(job), files: Map([]), }),
          ),
        )
      } else {
        None
      },
    }
  }
  // Metadata jobs keep their descriptor lease until acknowledgement. DNS has
  // no external resource to retain, so a cancelled lookup can finish privately.
  if operation is (ResolveHost | ReadWatchEvents) {
    wait()
  } else {
    @async.protect_from_cancel(wait)
  }
}

///|
#borrow(path)
extern "C" fn start_native_job(
  operation : Int32,
  path : Bytes,
  path_length : Int32,
  parent : @types.Fd,
  request : Int32,
  capacity : Int32,
  follow : Bool,
  notify : @types.Fd,
) -> NativeJob = "moonrun_native_job_start"

///|
extern "C" fn native_job_is_null(job : NativeJob) -> Bool = "moonrun_native_job_is_null"

///|
extern "C" fn join_native_job(job : NativeJob) -> Unit = "moonrun_native_job_join"

///|
extern "C" fn native_job_result(job : NativeJob) -> Int32 = "moonrun_native_job_result"

///|
extern "C" fn native_job_error(job : NativeJob) -> Int32 = "moonrun_native_job_error"

///|
extern "C" fn native_job_buffer(job : NativeJob) -> Bytes = "moonrun_native_job_buffer"

///|
extern "C" fn free_native_job(job : NativeJob) -> Unit = "moonrun_native_job_free"

///|
extern "C" fn detach_native_job(job : NativeJob) -> Unit = "moonrun_native_job_detach"

///|
extern "C" fn cancel_native_job(job : NativeJob) -> Unit = "moonrun_native_job_cancel"

///|
extern "C" fn native_job_take_fd(job : NativeJob) -> @types.Fd = "moonrun_native_job_take_fd"
