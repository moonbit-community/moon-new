///|
pub(all) enum IoOperation {
  Read
  Write
  Receive(Bytes)
  Send(Bytes)
  Connect(Bytes)
  Accept(Int32)
  WatchDirectory(FixedArray[Byte])
}

///|
pub fn IoOperation::event(self : IoOperation) -> Int32 {
  match self {
    Read | Receive(_) | Accept(_) | WatchDirectory(_) => 1
    Write | Send(_) | Connect(_) => 2
  }
}

///|
// Guest completion tokens are handles, never native OVERLAPPED pointers.
// No OS operation retains a pointer into guest linear memory.
pub(all) struct IoResult {
  operation : IoOperation
  length : Int32
  data : Bytes
  position : Int64
  flags : Int32
  mut task : @async.Task[Unit]?
  mut result : JobResult?
  mut pending : Bool
  mut fd : Int64?
  mut peer : Bytes?
}
