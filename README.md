# moon-new

Create a default MoonBit project using the bundled official starter template.
The CLI lives in the root package and supports native and Wasm execution.
Git repository templates (`--template`) are being implemented in
[phase two](docs/phase-2.md); the CLI option is not available yet.

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

## Development

```sh
moon check --target native
moon check --target wasm
moon build --target native
moon build --target wasm
moon test --target native
moon test --target wasm
MOON_NEW_TEST_TARGET=wasm moon test tests/cli_test.mbt --target native
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
