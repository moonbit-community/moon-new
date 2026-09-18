# moon-new

Create a default MoonBit project using the bundled official starter template.
The CLI lives in the root package and supports native and Wasm execution.
Git repository templates (`--template`) are planned for a later phase.

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

Git initializes only after generation, unless the destination is already in a
working tree. Missing or failing Git is a warning. README symlink failure falls
back to an ordinary copy with a warning. Quiet mode hides success output while
retaining warnings and errors. Exit codes are 0 (success), 1 (creation failure),
and 2 (argument errors).

The bundled template is pinned to official Moon `e4f45e4`. It is embedded with
`dev_build` and rendered with `bobzhang/liquid`; generation works offline and
never executes `moon new`. See [the design](docs/phase-1.md) and
[implementation plan](docs/phase-1-implementation.md).

## Development

```sh
moon check --target native
moon check --target wasm
moon test --target native
moon test --target wasm
moon build --target native
moon build --target wasm
python3 tests/cli.py -- ./_build/native/debug/build/moon-new.exe
python3 tests/cli.py -- moonrun ./_build/wasm/debug/build/moon-new.wasm --
python3 tests/package.py
moon info && moon fmt
```

Use absolute executable/artifact paths for the CLI tests, which change working
directory to a temporary location. The test runner resolves those paths before
launching commands. CI covers macOS ARM64, Linux x86_64, and Windows x86_64.
Only platforms with a completed run should be described as verified.

## License

[Apache-2.0](LICENSE). The bundled starter is derived from the official Moon
project under the same license; see [template provenance](template/README.md).
