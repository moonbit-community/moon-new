///|
pub(all) enum ProcessHandle {
  Child(Child)
  External(ExternalProcess)
}

///|
pub struct ExternalProcess {
  fd : @types.Fd
  priv mut references : Int32
}

///|
pub fn ExternalProcess::release(self : ExternalProcess) -> Unit {
  self.references -= 1
  if self.references == 0 {
    ignore(@sys.close_guest_pipe(self.fd))
  }
}

///|
fn poll_process(
  handle : @types.Fd,
  pid : Int32,
) -> Int32 raise @os_error.OSError {
  if @async.platform is Windows {
    let ready = @sys.native_process_ready(handle)
    if ready <= 0 {
      raise @os_error.OSError(
        if ready == 0 {
          997
        } else {
          @os_error.get_errno()
        },
        context="process readiness",
      )
    }
  }
  let output = Ref(0)
  if @sys.native_process_result(handle, pid, output) < 0 {
    raise @os_error.OSError(@os_error.get_errno(), context="process result")
  }
  output.val
}

///|
pub(all) struct SpawnOptions {
  command : String
  args : Array[String]
  env : Array[String]
  stdio : Array[@resource.Resource?]
  mut cwd : String
  orphan : Bool
  mut no_console : Bool
  mut child : Child?
}

///|
pub struct Child {
  native : @sys.NativeChild
  identity : Int64
  completion : FixedArray[@types.Fd]?
  mut result : Int32?
  mut error : Int32
  mut consumed : Bool
  mut handles : Int32
  mut closed : Bool
}

///|
fn Child::release_if_finished(self : Child) -> Unit {
  if self.consumed && self.handles == 0 && !self.closed {
    self.close()
  }
}

///|
fn Child::close(self : Child) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  if self.completion is Some(pipe) {
    ignore(@sys.close_guest_pipe(pipe[0]))
    ignore(@sys.close_guest_pipe(pipe[1]))
  }
  @sys.free_child(self.native)
}

///|
pub async fn HostProcess::signal(
  self : HostProcess,
  pid : Int32,
  signal : Int32,
) -> Unit {
  guard self.children.get(pid) is Some(child) && !child.consumed else {
    if self.policy is None {
      @sys.signal_process_pid(pid, signal)
      return
    }
    self.stdio.deny("process signal")
    return
  }
  if child.result is None {
    @sys.child_signal(child.native, signal)
  }
}

///|
pub fn ExternalProcess::retain(self : ExternalProcess) -> Unit {
  self.references += 1
}
