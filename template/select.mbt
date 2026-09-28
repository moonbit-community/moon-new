///|
pub(all) suberror TemplateError {
  TemplateError(String)
}

///|
pub impl Show for TemplateError with fn output(self, logger) {
  let TemplateError(message) = self
  logger.write_string(message)
}

///|
pub extend TemplateError with Show::{output, to_string}

///|
/// Apply the selected root's moon.new.json. Each result pairs an entry with
/// whether its contents should be rendered. Paths and link targets always render.
pub fn select(
  entries : Array[@repository.Entry],
  warnings? : Array[String] = [],
) -> Array[(@repository.Entry, Bool)] raise {
  let mut fields : Map[String, Json] = Map([])
  for entry in entries {
    if entry.path == "moon.new.json" {
      guard entry.mode == "100644" || entry.mode == "100755" else {
        raise TemplateError("moon.new.json must be an ordinary file")
      }
      let value = @json.parse(@utf8.decode(entry.content)) catch {
        error => raise TemplateError("Could not parse moon.new.json: \{error}")
      }
      guard value is Object(object) else {
        raise TemplateError("moon.new.json must contain an object")
      }
      fields = object
      break
    }
  }
  let config : Map[String, Array[String]] = Map([])
  for key, value in fields {
    guard key is ("include" | "exclude" | "ignore") else {
      raise TemplateError("Unknown moon.new.json field: \{key}")
    }
    guard value is Array(values) else {
      raise TemplateError(
        "moon.new.json field \{key} must be an array of strings",
      )
    }
    config[key] = values.map(value => {
      guard value is String(text) else {
        raise TemplateError(
          "moon.new.json field \{key} must be an array of strings",
        )
      }
      text
    })
  }
  let included = config.get("include")
  if included is Some(_) && config.contains("exclude") {
    warnings.push(
      "moon.new.json contains both include and exclude; ignoring exclude",
    )
  }
  let patterns = match included {
    Some(_) => included
    None => config.get("exclude")
  }
  let rules = []
  for pattern in patterns.unwrap_or([]) {
    if parse_rule(pattern) is Some(rule) {
      rules.push(rule)
    }
  }
  let ignored = config
    .get("ignore")
    .unwrap_or([])
    .map(path => {
      let parts = path
        .split("/")
        .filter(part => part != "." && part != "")
        .to_array()
      guard !path.has_prefix("/") &&
        !path.contains("\\") &&
        !path.contains(":") &&
        !parts.contains("..") else {
        raise TemplateError("Invalid ignore path in moon.new.json: \{path}")
      }
      parts.map(part => part.to_owned()).join("/")
    })
  let selected = []
  for entry in entries {
    let path = entry.path
    if path == "moon.new.json" ||
      path.split("/").any(part => part.to_lower() == ".git") ||
      ignored.any(prefix => {
        prefix == "" || path == prefix || path.has_prefix(prefix + "/")
      }) {
      continue
    }
    guard entry.mode != "160000" else {
      raise TemplateError("Submodules are unsupported: \{path}")
    }
    guard !@git.is_lfs_pointer(entry.content) else {
      raise TemplateError("Git LFS is unsupported: \{path}")
    }
    let render = if patterns is None {
      true
    } else {
      let matches = matches_content(rules, path)
      if included is Some(_) {
        matches
      } else {
        !matches
      }
    }
    if render || entry.mode == "120000" {
      ignore(@utf8.decode(entry.content)) catch {
        _ =>
          raise TemplateError(
            "Template is not valid UTF-8: \{path}; exclude binary contents from rendering",
          )
      }
    }
    selected.push((entry, render))
  }
  selected
}
