# Bundled default template

The files in `assets/` are the literal `content` strings from
[Moon e4f45e4](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/moonbuild/template/moon_new_template.toml),
including empty files and exact final-newline behavior. They are Apache-2.0
licensed, as is the source project. `template.mbt` preserves the inventory,
symlink target, and executable flags. Do not edit generated `.mbt` files.

`moon check` regenerates embedded constants via `dev_build` and `:embed --text`.
Commit both assets and generated files. When updating the pinned snapshot,
update the inventory and independent official-output fixtures together.
