# Phase 1: Default Project Creation

Status: product design and implementation mechanisms agreed; implementation is
present. See [the implementation plan](phase-1-implementation.md) and
[validation status](validation.md). Public delivery and all three platform runs
remain required for phase-one acceptance.

## Agreed scope

- Implement default MoonBit project creation.
- Defer Git repository templates and the `--template` option to a later phase.
- Preserve compatibility with the official command's normal usage and default
  generated project. Deliberate changes to edge-case behavior must be specified
  and covered by acceptance cases.
- Support macOS, Linux, and Windows. Each platform requires validation before
  phase 1 is considered complete.
- Distribute through Mooncakes under `moonbit-community/moon-new`, supporting
  both direct execution with `moonx` and installation with `moon install`.
- Separate downloadable executables and a GitHub Release pipeline are outside
  phase 1.

## Reference behavior

The inspected reference is `moon 0.1.20260916`, commit `e4f45e4`:

- [Command arguments and naming](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/moon/src/cli/new.rs)
- [Project generation](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/moonbuild/src/new.rs)
- [Default template](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/moonbuild/template/moon_new_template.toml)
- [Git operations](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/moonutil/src/git.rs)

These sources describe the reference behavior, not a requirement to reproduce
every implementation detail or edge case.

## Default-template versioning

- Use the inspected `e4f45e4` template as the initial fixed snapshot.
- Bundle the snapshot with the program. Project generation does not fetch a
  template or invoke an installed official `moon new`.
- Upgrade the snapshot explicitly through reviewed repository changes and
  compatibility tests; do not silently follow a moving upstream version.
- Preserve the snapshot's complete file inventory, including agent guidance,
  Git hook files, and Copilot setup workflow.
- The generated project retains its official `cmd/main` executable package and
  `preferred_target = "wasm"`, independently of this tool's own package layout.

## Agreed creation behavior

### Command-line interface

```text
moon-new <PATH> [--user <USER>] [--name <NAME>] [-q | --quiet]
moon-new -h | --help
```

- The destination path is required for creation; there is no interactive mode.
- Support `--user`, `--name`, `-h` / `--help`, and `-q` / `--quiet`.
- Other options inherited from the official `moon` program, including
  `--verbose`, `--trace`, `--target-dir`, and `--dry-run`, are out of scope and
  must be rejected rather than silently ignored.
- Quiet mode suppresses success messages and ordinary Git initialization output.
  Warnings and errors remain visible.
- Help and success messages go to stdout; warnings and errors go to stderr.
  Exit codes are `0` for success, `1` for creation failure, and `2` for argument
  errors. Warning-only Git failures retain exit code `0`.

### Naming compatibility

- Resolve the username from an explicit `--user`, then the local credentials
  file's `username`, then the literal `username`.
- An explicit `--user` skips credential lookup. Otherwise, use
  `MOON_HOME/credentials.json`, falling back to `HOME/.moon/credentials.json`
  on Unix or `USERPROFILE/.moon/credentials.json` on Windows when `MOON_HOME`
  is unset. If the environment cannot establish that directory, warn and use
  `username`; no system user-directory lookup is attempted. This environment-only
  fallback is an explicitly accepted difference from the official command.
  Parse it with `moonbitlang/core/json`; no network request or authenticated
  session is required. Standard JSON is supported; the official command's
  additional lenient syntax, including comments and trailing commas, is not.
  Parse failures use the normal warning and username fallback behavior.
  This is an explicitly accepted exception to exact credential syntax compatibility.
- Accept a nonempty username consisting of charclass Unicode alphanumeric
  characters, dashes, and underscores, without a local length limit.
  The user accepted charclass's Letter-or-Number semantics, which differ from
  the official Rust predicate for some alphabetic combining marks such as
  U+0345. Track this upstream instead of adding a local compatibility table.
- Resolve the project name from an explicit `--name`, otherwise from the
  reference path `file_stem` behavior, including its `hello` fallback. For
  example, directory `foo.bar` produces project name `foo`.
- Validate project names against `[A-Za-z_][A-Za-z0-9_-]*`.
- Names ending in `_test` or `_wbtest` produce a warning but are accepted.
- The module identity is `<username>/<project-name>`; the destination directory
  name is independent of an explicitly selected project name.

### Destination and failure cleanup

- Accept only a nonexistent destination or an existing empty directory.
- Hidden entries count as contents. A directory containing `.git`, `.DS_Store`,
  or an unrelated file is not an eligible destination.
- Reject an ineligible destination without changing its contents.
- Reject a destination that is itself a symbolic link, including a dangling
  link. Follow parent-directory symbolic links normally and preserve `..`
  traversal semantics. Missing ancestors may be created as needed.
- On a file-generation failure handled by the program, restore the destination
  to its original state: remove a newly created destination, or retain an
  originally empty directory with no generated contents.
- Forced process termination and power-loss recovery are outside this guarantee.
- If cleanup itself fails, report the remaining paths instead of claiming that
  restoration succeeded.
- Cleanup may remove ancestors created by this invocation, but only while
  empty; it does not remove pre-existing ancestors.

See [the destination policy decision](adr/0001-require-empty-destinations.md).

### Git initialization

- After successful file generation, retain the official Git initialization
  behavior: skip initialization inside an existing Git working tree, otherwise
  attempt to initialize a repository.
- Git being unavailable or initialization failing produces a warning, but does
  not make project creation fail or trigger removal of the generated project.
- Do not automatically stage files, create a commit, configure a remote, or
  enable the generated Git hook.

### README fallback

- Attempt to create `README.md` as a symbolic link to `README.mbt.md`.
- If symbolic link creation fails, fall back to an ordinary copy and report the
  fallback. The copied files will not remain synchronized automatically.
- Failure to create the fallback copy is a file-generation failure.

## Distribution and platform acceptance

The public module identity is `moonbit-community/moon-new`. Users must be able to
create a project with either flow:

```sh
moonx moonbit-community/moon-new hello --user tester

moon install moonbit-community/moon-new
moon-new hello --user tester
```

Run the two examples in separate clean locations. Both flows must expose the
same creation behavior; users must not need a `/cmd/main` package suffix or an
explicit target flag. Supplying no destination still produces the agreed
missing-argument error, and `--help` must work through either entrypoint.

Registry delivery requires a published module version, an available prebuilt
Wasm asset for `moonx`, and a successful native install. Local build or install
checks do not by themselves complete this public distribution acceptance.

Platform support follows the MoonBit toolchain. The initial acceptance matrix is:

| Operating system | Architecture |
| --- | --- |
| macOS | ARM64 |
| Linux | x86_64 |
| Windows | x86_64 |

Validate both the Wasm execution path and native executable on these platforms.
Additional toolchain-supported architectures are not a separate binary-release
commitment in phase 1 and must not be described as tested without evidence.

## Acceptance coverage

- The generated file inventory, file contents, symbolic link, and Unix executable
  permission match the selected official template, except for the agreed README
  fallback.
- Explicit and default names, credential fallback, invalid names, and reserved
  test-file suffixes follow the reference behavior, subject to the agreed
  strict-JSON, charclass Unicode, and home-directory fallback differences.
- Missing or unknown command-line arguments fail without creating a project;
  help works without a destination.
- Nonexistent and empty destinations succeed; populated destinations, including
  those with only hidden entries, are rejected without changes.
- Handled generation failures restore absent and empty destinations correctly.
- Git initialization is skipped inside a working tree; unavailable or failing
  Git produces a warning without failing creation.
- README symbolic-link failure falls back to an identical ordinary copy;
  failure of that copy triggers generation failure cleanup.
- Quiet mode hides successful creation output but preserves diagnostics.
- A generated project passes `moon check` and `moon test`, and its entry point
  prints `Hello`. The default template contains no test cases.
