///|
#external
pub type Operation

///|
#external
pub type NativeJob

///|
#external
pub type Worker

///|
pub extern "C" fn Operation::raw(self : Operation) -> NativeJob = "moonrun_operation_raw"

///|
pub extern "C" fn Operation::ret(self : Operation) -> Int32 = "moonrun_operation_ret"

///|
pub extern "C" fn Operation::error(self : Operation) -> Int32 = "moonrun_operation_error"

///|
pub extern "C" fn Operation::buffer(self : Operation) -> Bytes = "moonrun_operation_buffer"

///|
pub extern "C" fn Operation::take_fd(self : Operation) -> Fd = "moonrun_operation_take_fd"

///|
pub extern "C" fn Operation::close(self : Operation) -> Unit = "moonrun_operation_free"

///|
pub extern "C" fn run_job(job : NativeJob) -> Unit = "moonrun_native_run_job"

///|
pub fn Operation::run(self : Operation) -> Unit {
  run_job(self.raw())
}

///|
#borrow(first, second)
extern "C" fn path_operation(
  kind : Int32,
  first : Bytes,
  first_length : Int32,
  second : Bytes,
  second_length : Int32,
  value : Int32,
  flag : Bool,
) -> Operation = "moonrun_operation_path"

///|
pub fn path_job(
  kind : Int32,
  first : String,
  second~ : String = "",
  value~ : Int32 = 0,
  flag~ : Bool = false,
) -> Operation raise {
  let first = os_path(first)
  let second = os_path(second)
  path_operation(
    kind,
    first,
    first.length(),
    second,
    second.length(),
    value,
    flag,
  )
}

///|
#borrow(path)
extern "C" fn open_operation(
  path : Bytes,
  length : Int32,
  access : Int32,
  create : Int32,
  append : Bool,
  sync : Int32,
  mode : Int32,
  request : Int32,
  capacity : Int32,
) -> Operation = "moonrun_operation_open"

///|
pub fn open_job(
  path : String,
  access : Int32,
  create : Int32,
  append : Bool,
  sync : Int32,
  mode : Int32,
  request : Int32,
  capacity : Int32,
) -> Operation raise {
  let path = os_path(path)
  open_operation(
    path,
    path.length(),
    access,
    create,
    append,
    sync,
    mode,
    request,
    capacity,
  )
}

///|
#borrow(path)
extern "C" fn stat_operation(
  kind : Int32,
  path : Bytes,
  length : Int32,
  fd : Fd,
  request : Int32,
  capacity : Int32,
  follow : Bool,
) -> Operation = "moonrun_operation_stat"

///|
pub fn stat_job(
  path : String,
  fd : Fd,
  request : Int32,
  capacity : Int32,
  follow : Bool,
) -> Operation raise {
  let path = os_path(path)
  stat_operation(11, path, path.length(), fd, request, capacity, follow)
}

///|
pub fn fstat_job(fd : Fd, request : Int32, capacity : Int32) -> Operation {
  stat_operation(12, b"", 0, fd, request, capacity, false)
}

///|
pub extern "C" fn directory_job(
  fd : Fd,
  capacity : Int32,
  restart : Bool,
) -> Operation = "moonrun_operation_directory"

///|
pub extern "C" fn file_job(kind : Int32, fd : Fd, value : Int32) -> Operation = "moonrun_operation_file"

///|
pub extern "C" fn start_worker(
  job : NativeJob,
  id : Int32,
  notify : Fd,
  bus : NativeEventBus,
  source : Int64,
  token : Int64,
) -> Worker = "moonrun_native_worker_start"

///|
pub extern "C" fn Worker::done(self : Worker) -> Bool = "moonrun_native_worker_done"

///|
pub extern "C" fn Worker::cancel(self : Worker) -> Unit = "moonrun_native_worker_cancel"

///|
pub extern "C" fn Worker::close(self : Worker) -> Unit = "moonrun_native_worker_free"

///|
#borrow(data)
extern "C" fn io_operation(
  fd : Fd,
  data : Bytes,
  length : Int32,
  reading : Bool,
  socket : Bool,
  flags : Int32,
  position : Int64,
) -> Operation = "moonrun_operation_io"

///|
pub fn read_job(
  fd : Fd,
  length : Int32,
  position : Int64,
  socket~ : Bool = false,
  flags~ : Int32 = 0,
) -> Operation {
  io_operation(fd, b"", length, true, socket, flags, position)
}

///|
pub fn write_job(
  fd : Fd,
  data : Bytes,
  position : Int64,
  socket~ : Bool = false,
  flags~ : Int32 = 0,
) -> Operation {
  io_operation(fd, data, data.length(), false, socket, flags, position)
}

///|
pub extern "C" fn sleep_job(milliseconds : Int32) -> Operation = "moonrun_operation_sleep"

///|
#borrow(address, data)
extern "C" fn network_operation(
  kind : Int32,
  fd : Fd,
  address : Bytes,
  address_length : Int32,
  data : Bytes,
  length : Int32,
  flags : Int32,
) -> Operation = "moonrun_operation_network"

///|
pub fn network_job(
  kind : Int32,
  fd : Fd,
  address : Bytes,
  data : Bytes,
  length : Int32,
  flags : Int32,
) -> Operation {
  network_operation(kind, fd, address, address.length(), data, length, flags)
}

///|
pub extern "C" fn Operation::peer(self : Operation) -> Bytes = "moonrun_operation_peer"

///|
pub extern "C" fn Worker::is_null(self : Worker) -> Bool = "moonrun_native_worker_is_null"

///|
pub extern "C" fn Worker::has_notice(self : Worker) -> Bool = "moonrun_native_worker_notice"

///|
pub extern "C" fn Worker::take_notice(self : Worker) -> Bool = "moonrun_native_worker_take_notice"

///|
pub extern "C" fn Worker::id(self : Worker) -> Int32 = "moonrun_native_worker_id"

///|
pub extern "C" fn Worker::poll(self : Worker) -> Bool = "moonrun_native_worker_poll"
