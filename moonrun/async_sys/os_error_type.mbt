///|
pub(all) suberror OSError {
  OSError(Int32, context~ : String)
}

///|
pub extern "C" fn get_errno() -> Int32 = "moonrun_native_get_errno"

///|
extern "C" fn error_bytes(code : Int32) -> Bytes = "moonrun_error_message"

///|
pub impl Show for OSError with fn output(self, logger) {
  let OSError(code, context~) = self
  let terminated = error_bytes(code)
  let bytes = terminated[:terminated.length() -
    (if platform is Windows { 2 } else { 1 })]
  let message = if platform is Windows {
    @utf16.decode_lossy(bytes, endianness=Little)
  } else {
    @utf8.decode_lossy(bytes)
  }
  logger <+ "OSError(\{context}: \{message.trim_end(chars="\r\n")})"
}

///|
pub impl Debug for OSError with fn to_repr(self) {
  Repr::opaque_("OSError", Repr::string(self.to_string()))
}

///|
pub extend OSError with Show::{to_string}

///|
pub fn check_errno(context : String) -> Unit raise OSError {
  raise OSError(get_errno(), context~)
}

///|
pub fn OSError::is_EINTR(self : OSError) -> Bool {
  let OSError(code, ..) = self
  !(platform is Windows) && code == 4
}

///|
pub fn OSError::is_ENOENT(self : OSError) -> Bool {
  let OSError(code, ..) = self
  code == 2 || (platform is Windows && code == 3)
}

///|
pub fn OSError::is_EEXIST(self : OSError) -> Bool {
  let OSError(code, ..) = self
  if platform is Windows {
    code is (80 | 183)
  } else {
    code == 17
  }
}

///|
pub fn OSError::is_nonblocking_io_error(self : OSError) -> Bool {
  let OSError(code, ..) = self
  match platform {
    Linux => code is (11 | 115)
    MacOS => code is (35 | 36)
    Windows => code is (996 | 997 | 10035 | 10036)
  }
}

///|
pub let errno_ENOTDIR : Int32 = if platform is Windows { 267 } else { 20 }

///|
pub let errno_ENOTSUP : Int32 = match platform {
  Windows => 50
  MacOS => 45
  Linux => 95
}

///|
pub fn OSError::is_EACCES(self : OSError) -> Bool {
  let OSError(code, ..) = self
  code == (if platform is Windows { 5 } else { 13 })
}

///|
pub fn OSError::is_ECONNREFUSED(self : OSError) -> Bool {
  let OSError(code, ..) = self
  code ==
  (match platform {
    Windows => 1225
    MacOS => 61
    Linux => 111
  })
}

///|
pub fn OSError::is_ERROR_NOTIFY_ENUM_DIR(self : OSError) -> Bool {
  let OSError(code, ..) = self
  platform is Windows && code == 1022
}

///|
#deprecated
pub extend OSError with Show::{output}

///|
#deprecated
pub extend OSError with Debug::{to_repr}
