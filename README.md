# moon-new

Create a MoonBit project from the bundled official starter or a Git repository.
The CLI lives in the root package and supports native and Wasm execution.

## Usage

After publication to Mooncakes, the public entrypoints are:

```sh
moonx moonbit-community/moon-new hello --user yourname
moon install moonbit-community/moon-new
moon-new hello --user yourname
```

Until registry publication, run from this checkout:

```sh
moon run . -- hello --user yourname
moon install --path . --bin ./local-bin
./local-bin/moon-new hello --user yourname
```

```text
moon-new <PATH> [--user <USER>] [--name <NAME>] [-q | --quiet]
moon-new <PATH> --template <SOURCE> [--subdir <PATH_IN_REPO>]
         [--branch <BRANCH> | --tag <TAG> | --rev <COMMIT>]
         [--user <USER>] [--name <NAME>] [-q | --quiet]
moon-new -h | --help
```

The destination must be absent or completely empty, including hidden entries.
A destination that is itself a symbolic link is rejected; links in parent
paths are followed. A handled generation failure removes only files and empty
directories created by this invocation. Forced termination is not recoverable.

The username comes from `--user`, then the local MoonBit credentials, then
`username`. Credentials use strict JSON. `MOON_HOME` takes precedence over
`HOME/.moon` on Unix and `USERPROFILE/.moon` on Windows. An unavailable home
directory produces a warning and the default username. Names use charclass's
Unicode letter/number categories plus `-` and `_`; some combining marks accepted
by official Moon are not accepted here.

Git initializes through the bit library after generation, unless the destination
is already in a working tree. No Git executable is required. New repositories
start on `main`; global Git configuration and `GIT_CONFIG_*` overrides are not
read. Initialization failure is a warning. README symlink failure falls
back to an ordinary copy with a warning. Quiet mode hides success output while
retaining warnings and errors. Exit codes are 0 (success), 1 (creation failure),
and 2 (argument errors).

The bundled template is pinned to official Moon `e4f45e4`. It is embedded with
`dev_build` and rendered with `moonbit-community/liquid`; generation works offline and
never executes `moon new`. See [the design](docs/phase-1.md) and
[implementation notes](docs/phase-1-implementation.md).

## Git templates

```sh
moon-new hello --template owner/repo --user yourname
moon-new hello --template https://github.com/owner/repo.git --tag v1
moon-new hello --template ./local-repo --subdir examples/starter --branch main
```

Sources may be local Git repositories (including bare repositories), public
HTTPS Git URLs, or GitHub `owner/repo` shorthand. Local sources use committed
contents and ignore dirty or untracked files. Selection defaults to local HEAD
or the remote's advertised default branch. `--rev` requires a full commit hash;
`--branch`, `--tag`, and `--rev` are mutually exclusive. These options and
`--subdir` require `--template`.

Liquid expands file paths, directory names, selected UTF-8 file contents, and
symbolic-link targets. The only supplied variables are `username` and `module`
(the short project name), so write `{{username}}/{{module}}` for the full module
identity. Unknown variables, invalid Liquid, output path escapes and collisions
fail generation. Paths must be relative, without empty, `.`, `..`, backslash,
colon, NUL, or `.git` components; Windows also rejects reserved filenames.

An optional `moon.new.json` at the selected template root accepts only string
arrays named `include`, `exclude`, and `ignore`:

```json
{
  "exclude": ["assets/**", "*.png"],
  "ignore": [".github", "template-notes.md"]
}
```

Without `include` or `exclude`, all ordinary file contents are rendered.
`include` is a whitelist; an empty array renders no contents. With only
`exclude`, matched contents are copied unchanged. When both are present,
`include` wins and a warning is emitted. Patterns follow cargo-generate's
Gitignore-style matching, including negation, character classes, escapes and
`**`; they match source paths before interpolation. Literal braces must be
escaped in patterns (for example `"\\{\\{module\\}\\}.txt"` in JSON).

`ignore` contains literal relative paths, not patterns, and omits files or
whole subtrees before rendering. Missing entries are harmless. The config
itself and Git metadata are omitted. Parent configurations are not inherited.
There is no special `.liquid` suffix handling. Binary files must be excluded
from content rendering; copied bytes are preserved exactly, while paths still
expand.

Symlinks are preserved, including external and dangling targets. If the OS
cannot create one, generation warns and attempts to copy its target as a file
or directory using only this generation's rendered contents. Missing, external
or cyclic fallback targets fail and trigger rollback. Executable file modes
are preserved where supported.

Authentication, SSH, submodules, Git LFS downloads, custom variables and hooks
are unsupported. Required submodules or LFS pointers fail unless omitted with
`ignore`. Production Git operations use bit libraries without spawning Git.
See [the phase-two design](docs/phase-2.md).

## Development

```sh
moon check --target native
moon check --target wasm
moon build --target native
moon build --target wasm
moon test --target native
moon test --target wasm
MOON_NEW_TEST_TARGET=wasm moon test tests/cli_test.mbt --target native
MOON_NEW_TEST_TARGET=wasm moon test tests/template_cli_test.mbt --target native
MOON_NEW_TEST_REMOTE=1 moon test tests/template_cli_test.mbt --target native
MOON_NEW_TEST_REMOTE=1 MOON_NEW_TEST_TARGET=wasm moon test tests/template_cli_test.mbt --target native
MOON_NEW_TEST_REMOTE=1 moon test repository/repository_test.mbt --target native
MOON_NEW_TEST_REMOTE=1 moon test repository/repository_test.mbt --target wasm
moon info && moon fmt
```

Run these commands from the repository root. All tests are written in MoonBit.
The native suite includes CLI and package acceptance tests. Build the CLI before
running them; `MOON_NEW_TEST_TARGET` selects the CLI backend under test, while
the acceptance harness itself runs natively. In PowerShell, set
`$env:MOON_NEW_TEST_TARGET = "wasm"` before the CLI test command and remove it
afterward. The package test uses `unzip` on Unix and the system `tar` on Windows.
Unix permission assertions use `sh`, `stat`, and `readlink`. Repository fixtures
use Git to create independent committed inputs; production code does not invoke
Git. Remote smoke tests access the public `octocat/Hello-World` repository and
are skipped unless explicitly enabled.
CI covers macOS ARM64, Linux x86_64, and Windows x86_64.
Only platforms with a completed run should be described as verified.

## License

[Apache-2.0](LICENSE). The bundled starter is derived from the official Moon
project under the same license; see [template provenance](template/README.md).
