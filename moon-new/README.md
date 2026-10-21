# moon-new

Create a MoonBit project from the bundled hello starter or a Git repository.

Currently, only the Wasm target is supported.

## Usage

Run directly with `moonx`:

```sh
moonx moonbit-community/moon-new hello --user yourname
```

```text
moon-new <PATH> [--user <USER>] [--name <NAME>] [-q | --quiet]
moon-new <PATH> --template <SOURCE> [--subdir <PATH_IN_REPO>]
         [--branch <BRANCH> | --tag <TAG> | --rev <COMMIT>]
         [--user <USER>] [--name <NAME>] [-q | --quiet]
moon-new -h | --help
```

The destination must be absent or completely empty. `--name` overrides the project name inferred from the destination. The username comes from `--user`, then MoonBit login credentials, then the default `username`.

A new Git repository is initialized unless the destination is already inside one. No Git executable is required. `--quiet` hides success messages while keeping warnings and errors.

## Git templates

Use a public GitHub repository by name or full HTTPS URL:

```sh
moonx moonbit-community/moon-new hello --template moonbit-community/moonbit-template-hello
moonx moonbit-community/moon-new hello --template https://github.com/moonbit-community/moonbit-template-hello.git
```

Local Git repositories and subdirectories are also supported:

```sh
moonx moonbit-community/moon-new hello --template ./my-template
moonx moonbit-community/moon-new hello --template owner/repo --subdir templates/hello --tag v1
```

Local templates use committed contents; dirty and untracked files are ignored. The default revision is local HEAD or the remote's default branch. Use one of `--branch`, `--tag`, or `--rev` to select another revision; `--rev` requires a full commit hash. `--subdir` selects the directory whose contents become the project.

Private authentication, SSH, submodules, Git LFS downloads, custom variables, and generation hooks are not supported.

## Authoring a template

A template is a Git repository containing the files to generate. Use the [hello template](https://github.com/moonbit-community/moonbit-template-hello) as a reference. No template build or Mooncakes publication is needed.

### Variables and paths

Liquid expands file and directory names, selected UTF-8 file contents, and symbolic-link targets. Two variables are available throughout the template:

| Variable | Meaning | Example |
| --- | --- | --- |
| `username` | The resolved username, including an explicit `--user` | `tester` |
| `module` | The short project name, including an explicit `--name` | `hello` |

For example, set the module identity in `moon.mod`:

```toml
name = "{{username}}/{{module}}"
```

Name root source files `{{module}}.mbt`, `{{module}}_test.mbt`, and `{{module}}_wbtest.mbt`. There is no `package` variable; give subpackages explicit names such as `utils/utils.mbt`. There is no special `.liquid` suffix handling.

Unknown variables, invalid Liquid, paths escaping the destination, and output path collisions fail generation. Symlinks and executable modes are preserved where supported; if symlink creation fails, a copy is attempted using only the generated project's contents.

### File selection

All ordinary file contents are rendered by default. An optional `moon.new.json` at the selected template root controls rendering and omission:

```json
{
  "exclude": ["assets/**", ".github/workflows/**"],
  "ignore": ["TEMPLATE.md", "template-tests"]
}
```

- `include`: render only matching file contents; copy other contents unchanged.
- `exclude`: copy matching file contents unchanged; render the rest.
- `ignore`: omit literal relative paths or entire subtrees from the output.

Use either `include` or `exclude`; if both are present, `include` wins and a warning is emitted. `include: []` copies all file contents unchanged. Paths and symlink targets still expand regardless of content selection.

Patterns in `include` and `exclude` use Gitignore-style matching, including negation, character classes, escapes, and `**`. They match source paths before variable expansion. Escape literal braces in patterns, for example `"\\{\\{module\\}\\}.mbt"` in JSON. `ignore` does not accept patterns.

Exclude binary contents and files whose template syntax must remain literal, such as GitHub Actions workflows containing `${{ github.ref }}`. The example above preserves assets and workflows while omitting template-only notes and tests. `moon.new.json` and Git metadata are always omitted. When using `--subdir`, place the configuration inside that directory; parent configurations are not read.

## License

[Apache-2.0](LICENSE).
