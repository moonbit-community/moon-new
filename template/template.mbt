///|
pub(all) enum Entry {
  File(path~ : String, content~ : String, executable~ : Bool)
  Link(path~ : String, target~ : String)
}

///|
fn inventory() -> Array[Entry] {
  [
    File(path="moon.pkg", content=asset_00, executable=false),
    File(path="cmd/main/moon.pkg", content=asset_01, executable=false),
    File(path="cmd/main/main.mbt", content=asset_02, executable=false),
    File(path="{{package}}.mbt", content=asset_03, executable=false),
    File(path="moon.mod", content=asset_04, executable=false),
    File(path=".githooks/README.md", content=asset_05, executable=false),
    File(path=".githooks/pre-commit", content=asset_06, executable=true),
    File(path="LICENSE", content=asset_07, executable=false),
    File(path="{{package}}_wbtest.mbt", content=asset_08, executable=false),
    Link(path="README.md", target="README.mbt.md"),
    File(path="README.mbt.md", content=asset_10, executable=false),
    File(path=".gitignore", content=asset_11, executable=false),
    File(
      path=".github/workflows/copilot-setup-steps.yml",
      content=asset_12,
      executable=false,
    ),
    File(path="{{package}}_test.mbt", content=asset_13, executable=false),
    File(path="AGENTS.md", content=asset_14, executable=false),
  ]
}

///|
/// Render the pinned template's file names and contents before creating files.
pub fn render(
  username : String,
  name : String,
) -> Array[Entry] raise TemplateError {
  let context = @liquid.LiquidContext::new()
  context.set("username", @liquid.string_value(username))
  context.set("module", @liquid.string_value(name))
  inventory().map(entry => {
    match entry {
      File(path~, content~, executable~) => {
        let parent = path.split("/").to_array()
        let package_name = if parent.length() > 1 {
          parent[parent.length() - 2].to_owned()
        } else {
          name
        }
        context.set("package", @liquid.string_value(package_name))
        File(
          path=render_text(path, context, source="file name: \{path}"),
          content=render_text(content, context, source=path),
          executable~,
        )
      }
      Link(..) => entry
    }
  })
}

///|
fn render_text(
  text : String,
  context : @liquid.LiquidContext,
  source~ : String,
) -> String raise TemplateError {
  match @liquid.compile(text).bind(template => template.render(context)) {
    Ok(output) => output
    Err(diagnostics) => {
      let messages = diagnostics.map(diagnostic => {
        let location = diagnostic.offset
          .map(offset => " at UTF-16 offset \{offset}")
          .unwrap_or("")
        "\{diagnostic.phase} [\{diagnostic.code}]\{location}: \{diagnostic.message}"
      })
      raise TemplateError("Could not render \{source}:\n" + messages.join("\n"))
    }
  }
}
