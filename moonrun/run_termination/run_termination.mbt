///|
/// Guest termination is returned to the caller and never exits the host process.
pub(all) enum RunOutcome {
  Completed
  Exited(Int32)
  Signaled(Int32)
  Trapped(String)
} derive(Debug, Eq)

///|
pub extend RunOutcome with Debug::{to_repr}

///|
pub extend RunOutcome with Eq::{equal, not_equal}
