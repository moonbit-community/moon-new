# Phase 1 implementation

[Behavior contract](phase-1.md) · [Validation](validation.md) ·
[Development commands](../README.md#development)

## Packages and dependencies

| Package | Responsibility |
| --- | --- |
| Root executable | Arguments, diagnostics, output routing, exit codes |
| `project` | Credentials, names, paths, file creation, rollback, Git |
| `template` | Embedded assets, fixed inventory, Liquid rendering |

The root executable installs as `moon-new` (`moon-new.exe` on Windows).
The module supports native and Wasm, with Wasm preferred. The generated
starter's separate `cmd/main` layout is unchanged.

Use core argparse/JSON, async filesystem/process APIs, and x/path. The user
approved Liquid engine (now `moonbit-community/liquid`) and
`moonbit-community/charclass`; versions live in
[moon.mod](../moon.mod). New non-official dependencies require confirmation.
Keep cross-package APIs small, avoid `internal` packages and speculative
frameworks, and call `@fs` directly. There is no injectable filesystem layer.

## Template pipeline

- `template/assets/` is authoritative. Preserve original bytes and trailing
  newlines; never hand-edit generated constants.
- `dev_build` uses `:embed --text` with explicit input/output paths and constant
  names. Commit both raw assets and generated `.mbt` sources. Dependency builds
  use committed outputs; application builds, including installation, run rules.
- Ship hidden assets through `.moonignore`; declaring build inputs alone does
  not guarantee packaging. The package test checks all 14 assets and constants,
  deletes extracted constants, and verifies installation regenerates them.
- A typed inventory records paths, contents, executable flags, and link targets.
  No runtime manifest parser or directory scan is needed.
- Liquid renders the fixed snapshot's variables. Its selection does not establish
  general Liquid conformance or decide the future Git-template language.
  Keep the engine; do not replace it with a custom token substituter.
- Snapshot changes update inventory, assets, generated files, and independent
  official-output fixtures together. See [provenance](../template/README.md).

## Creation flow

1. Resolve credentials and names, validate, and render the complete inventory
   before changing the filesystem.
2. Check destination eligibility. Create missing ancestors individually and
   record only those created by this invocation. Recheck destination eligibility
   afterward: creating ancestors can make a `..` path resolve to existing content.
3. Open files with `CreateNew` and permission `0o666`; record them immediately
   before writing. Close handles on both success and failure. Create directories
   with `0o777`; ordinary permissions respect the process umask.
4. On Unix, set executable hooks to `0o755`; failure only warns. Use runtime
   `async.platform` for host behavior on both native and Wasm; skip chmod on Windows.
5. On link failure, copy the already-rendered target bytes and warn.
6. On generation failure, reverse the local created-path journal. Remove files
   and only empty created directories. Successful cleanup rethrows the original
   error; cleanup failures include the original cause and possible residual paths.
7. Run system Git using argv, inherited environment, and the destination as cwd.
   Capture output; failure only warns and leaves generated output intact.

Path handling preserves symlinks and `..` rather than lexically normalizing them.
A narrow helper supplies reference file-stem behavior, including Windows
absolute, rooted, and drive-relative paths. There is no staging directory,
recursive rollback deletion, or generic transaction framework.

## Diagnostics and tests

The CLI owns the array passed to `create(..., warnings~)`, making accumulated
warnings available on failure. Print them in order before an error, even in
quiet mode. Credential diagnostics omit tokens and parser source excerpts.
CLI filesystem errors identify the destination and then show the original cause;
do not parse library display strings or use internal errno-formatting APIs.

All tests are MoonBit. Use real temporary filesystems and child processes;
no production fault-injection flags or test-only filesystem adapters.
A valid name exceeding the host filename limit causes failure after earlier
files were written, testing cleanup of absent and originally empty destinations.
Exact fixtures come from official Moon, not the renderer under test. Compare
stable application diagnostic text exactly, but allow OS error wording to vary.
Coverage limits and uncompleted delivery checks belong in [validation](validation.md).

## Decision sources

- [Template-engine comparison](research/template-engines.md),
  [Liquid probes](research/template-liquid.md), [Unicode semantics](research/unicode-validation.md).
- Pinned Moon [moonx](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/moon/src/cli/moonx.rs),
  [installation](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/moon/src/cli/install_binary.rs),
  [registry assets](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/mooncake/src/registry/client.rs).
- Inspected async [filesystem](https://github.com/moonbitlang/async/blob/48f72f7683531883892211288ebd9f0476e61c6a/src/fs/pkg.generated.mbti)
  and [process](https://github.com/moonbitlang/async/blob/48f72f7683531883892211288ebd9f0476e61c6a/src/process/pkg.generated.mbti) APIs.
