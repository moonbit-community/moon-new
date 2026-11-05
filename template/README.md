# Bundled default template

The starter files in `assets/` are based on
[Moon e4f45e4](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/moonbuild/template/moon_new_template.toml),
with the Copilot setup workflow replaced by `stable_check.yml`. The other assets
preserve the upstream contents, including empty files and exact final-newline
behavior. They are Apache-2.0 licensed, as is the source project. `template.mbt`
preserves the inventory, symlink target, and executable flags. Do not edit
generated `.mbt` files.

The CI workflow checks formatting, warnings, and debug/release tests for all
targets on Linux, macOS, and Windows. Its GitHub Actions expressions are wrapped
in Liquid `{% raw %}` blocks so they survive template rendering unchanged.

`moon check` regenerates embedded constants via `dev_build` and `:embed --text`.
Commit both assets and generated files. When updating the assets, update the
inventory and `tests/fixtures/default.json` together. The fixture contains the
expected rendered output without Liquid raw blocks.
