///|
/// Native work owns all syscall inputs. Only `publish` runs on the VM thread.
pub struct Task {
  operation : @sys.Operation
  priv publish : () -> JobResult raise
  priv cleanup : (() -> Unit)?
  priv mut closed : Bool
}

///|
pub fn Task::Task(
  operation : @sys.Operation,
  publish? : () -> JobResult raise,
  cleanup? : () -> Unit,
) -> Task {
  {
    operation,
    closed: false,
    cleanup,
    publish: publish.unwrap_or_else(() => () => result(operation)),
  }
}

///|
pub fn result(operation : @sys.Operation) -> JobResult {
  {
    ret: operation.ret(),
    errno: operation.error(),
    data: operation.buffer(),
    opened: None,
  }
}

///|
pub fn Task::publish(self : Task) -> JobResult raise {
  guard !self.closed else { raise @sys.Invalid }
  (self.publish)()
}

///|
pub fn Task::run(self : Task) -> JobResult raise {
  guard !self.closed else { raise @sys.Invalid }
  defer self.close()
  self.operation.run()
  self.publish()
}

///|
pub fn Task::ready(result : JobResult) -> Task {
  Task(@sys.sleep_job(0), publish=() => result)
}

///|
pub fn Task::close(self : Task) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  self.operation.close()
  if self.cleanup is Some(cleanup) {
    cleanup()
  }
}
