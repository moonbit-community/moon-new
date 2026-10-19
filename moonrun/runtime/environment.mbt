///|
fn environment_entry(
  entries : Map[String, String],
  key : String,
) -> (String, String)? {
  if @async.platform is Windows {
    entries
    .iter()
    .find_first(pair => {
      environment_key_equal(pair.0, pair.0.length(), key, key.length())
    })
  } else {
    entries.get(key).map(value => (key, value))
  }
}

///|
fn set_environment_entry(
  entries : Map[String, String],
  key : String,
  value : String,
) -> Unit {
  if environment_entry(entries, key) is Some((existing, _)) && existing != key {
    entries.remove(existing)
  }
  entries[key] = value
}

///|
fn copy_environment(entries : Map[String, String]) -> Map[String, String] {
  let copied = Map([])
  for key, value in entries {
    set_environment_entry(copied, key, value)
  }
  copied
}
