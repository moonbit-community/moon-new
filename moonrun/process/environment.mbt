///|
pub(all) enum Environment {
  Entries(Array[EnvironmentEntry?])
  Wide(FixedArray[Byte])
  Builder(Array[(String, String)], Array[String])
}

///|
pub(all) enum EnvironmentEntry {
  Materialized(String)
  Added(String, String)
}

///|
pub fn EnvironmentEntry::materialize(self : EnvironmentEntry) -> String? {
  match self {
    Materialized(entry) => Some(entry)
    Added(key, value) =>
      if key.contains_char('\u0000') {
        None
      } else {
        Some("\{key}=\{truncate_nul(value)}")
      }
  }
}

///|
pub fn truncate_nul(text : String) -> String {
  match text.find("\u0000") {
    Some(index) => text[:index].to_owned()
    None => text
  }
}

///|
pub fn process_environment(
  entries : Array[String],
  extra : Array[(String, String)],
) -> Array[String] {
  let added = extra.filter_map(pair => {
    let (key, value) = pair
    if key.contains_char('\u0000') {
      None
    } else {
      Some((key, truncate_nul(value)))
    }
  })
  let result = added.map(pair => {
    let (key, value) = pair
    "\{key}=\{value}"
  })
  for entry in entries {
    let key = match entry.find("=") {
      Some(index) => entry[:index].to_owned()
      None => entry
    }
    if !added.any(pair => {
        let (existing, _) = pair
        @sys.environment_key_equal(
          existing,
          existing.length(),
          key,
          key.length(),
        )
      }) {
      result.push(entry)
    }
  }
  result
}

///|
pub fn Environment::finish(
  self : Environment,
) -> Array[String] raise @sys.HostError {
  match self {
    Entries(entries) =>
      entries
      .iter()
      .take_while(entry => entry is Some(_))
      .filter_map(entry => entry.unwrap().materialize())
      .to_array()
    Builder(extra, inherited) => process_environment(inherited, extra)
    Wide(buffer) => {
      let text = @utf16.decode(Bytes::from_array(buffer), endianness=Little) catch {
        _ => raise @sys.Invalid
      }
      text
      .split("\u0000")
      .take_while(entry => !entry.is_empty())
      .map(entry => entry.to_owned())
      .to_array()
    }
  }
}
