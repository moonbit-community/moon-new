///|
/// Render selected Git entries. Rules are evaluated against source paths.
pub fn render_repository(
  entries : Array[@repository.Entry],
  username : String,
  name : String,
  warnings? : Array[String] = [],
) -> Array[Entry] raise {
  let context = @liquid.LiquidContext::new()
  context.set("username", @liquid.string_value(username))
  context.set("module", @liquid.string_value(name))
  let output = select(entries, warnings~).map(pair => {
    let (entry, render) = pair
    let path = render_text(
      entry.path,
      context,
      source="file name: \{entry.path}",
    )
    if entry.mode == "120000" {
      Link(
        path~,
        target=render_text(
          @utf8.decode(entry.content),
          context,
          source="link target: \{entry.path}",
        ),
      )
    } else {
      File(
        path~,
        content=if render {
          @utf8.encode(
            render_text(@utf8.decode(entry.content), context, source=entry.path),
          )
        } else {
          entry.content
        },
        executable=entry.mode == "100755",
      )
    }
  })
  validate_paths(output)
  output
}

///|
/// Reject aliases, escapes and file/directory conflicts before writing anything.
fn validate_paths(entries : Array[Entry]) -> Unit raise TemplateError {
  let paths : Map[String, String] = Map([])
  let directories : Map[String, String] = Map([])
  for entry in entries {
    let path = match entry {
      File(path~, ..) | Link(path~, ..) => path
    }
    let components = path.split("/").map(part => part.to_owned()).to_array()
    for component in components {
      if component == "" ||
        component == "." ||
        component == ".." ||
        component.to_lower() == ".git" ||
        component.contains("\\") ||
        component.contains(":") ||
        component.contains("\u0000") {
        raise TemplateError("Invalid output path: \{path}")
      }
    }
    if entry is Link(target~, ..) && target.contains("\u0000") {
      raise TemplateError(
        "Invalid symbolic-link target in output path: \{path}",
      )
    }
    if @path.sep == '\\' {
      for component in components {
        let stem = component.split(".").to_array()[0].to_owned().to_upper()
        if component.has_suffix(".") ||
          component.has_suffix(" ") ||
          component
          .iter()
          .any(ch => ch.to_int() < 32 || "<>\"|?*".contains(ch.to_string())) ||
          [
            "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6",
            "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6",
            "LPT7", "LPT8", "LPT9", "COM¹", "COM²", "COM³", "LPT¹", "LPT²",
            "LPT³",
          ].contains(stem) {
          raise TemplateError("Invalid Windows output path: \{path}")
        }
      }
    }
    if paths.get(path) is Some(previous) {
      raise TemplateError("Output path collision: \{previous} and \{path}")
    }
    if directories.get(path) is Some(child) {
      raise TemplateError(
        "Output path collision: \{path} is also a directory for \{child}",
      )
    }
    let mut parent = ""
    for i in 0..<(components.length() - 1) {
      parent = if parent == "" {
        components[i]
      } else {
        parent + "/" + components[i]
      }
      if paths.get(parent) is Some(previous) {
        raise TemplateError(
          "Output path collision: \{previous} is also a directory for \{path}",
        )
      }
      directories[parent] = path
    }
    paths[path] = path
  }
}
