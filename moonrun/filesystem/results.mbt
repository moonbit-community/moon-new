///|
/// Results retained by the core filesystem ABI until the guest calls a getter.
pub(all) struct OperationResults {
  mut file_content : FixedArray[Byte]
  mut directory_entries : Array[String]
  mut error_message : String
}

///|
pub fn OperationResults::OperationResults() -> OperationResults {
  { file_content: [], directory_entries: [], error_message: "", }
}
