# Phase 1: Default project creation

Implemented locally; public delivery and the three-platform acceptance matrix
remain incomplete. See [implementation](phase-1-implementation.md) and
[validation](validation.md).

## Scope and reference

Provide default project creation through `moonbit-community/moon-new`.
Git templates (`--template`), interactive mode, downloadable executables, and a
GitHub Release pipeline are outside phase one.

The reference is Moon `e4f45e4`: [CLI](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/moon/src/cli/new.rs),
[generation](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/moonbuild/src/new.rs),
[template](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/moonbuild/template/moon_new_template.toml),
and [Git](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/moonutil/src/git.rs).
Compatibility covers normal usage and generated contents, subject to the explicit
differences below; it does not require identical internals or diagnostic text.

## CLI and diagnostics

```text
moon-new <PATH> [--user <USER>] [--name <NAME>] [-q | --quiet]
moon-new -h | --help
```

- Require a destination except for help. Reject unsupported options, including
  `--template`, `--verbose`, `--trace`, `--target-dir`, and `--dry-run`.
- Send help/success to stdout and warnings/errors to stderr. Quiet mode hides
  success and ordinary Git initialization output, never warnings or errors.
- Preserve warnings in encounter order before a later error. Credential parse
  and schema failures suggest `moon login` or `--user` without exposing tokens.
- Exit codes: `0` success (including Git warnings), `1` creation failure,
  `2` argument error.

## Names and credentials

- Username precedence: `--user`, credentials username, then `username`.
  Explicit `--user` skips credential lookup entirely.
- Read `MOON_HOME/credentials.json` if `MOON_HOME` is set, including empty or
  relative values. Otherwise use `HOME/.moon/credentials.json` on Unix
  (HOME may be empty), or nonempty `USERPROFILE/.moon/credentials.json` on
  Windows. No OS home lookup or tilde expansion; unknown home warns and falls back.
- Use strict JSON: string `token` required; string `username` optional, with
  missing/null meaning absent. Missing files and read/parse/schema failures
  warn and fall back; failure to open an existing file falls back silently.
  Valid credentials without a username fall back silently. Never modify credentials.
- Usernames must be nonempty charclass Unicode letters/numbers, `-`, or `_`,
  without a local length limit. The accepted U+0345 difference from Rust is
  tracked in [charclass #10](https://github.com/moonbit-community/charclass/issues/10).
- Project names use `--name` or reference `file_stem` semantics (`foo.bar` →
  `foo`, fallback `hello`), and must match `[A-Za-z_][A-Za-z0-9_-]*`.
  `_test` and `_wbtest` suffixes warn but remain valid.
- Module identity is `<username>/<project-name>`, independent of destination name.
  Strict JSON, charclass semantics, and environment-only home lookup are accepted
  compatibility differences; do not add local Unicode exceptions or lenient JSON.

## Creation and cleanup

- Bundle the complete `e4f45e4` snapshot, including guidance, hooks, and workflow.
  Generate offline without fetching templates or invoking official `moon new`.
  Snapshot updates require review and fixture updates. The generated project
  retains `cmd/main` and preferred target `wasm`.
- Accept only absent or completely empty destinations, including hidden entries.
  Reject files and destination symlinks, including dangling links. Follow parent
  symlinks and preserve OS traversal through `..`.
  See the [destination decision](adr/0001-require-empty-destinations.md).
- On handled generation failure, remove only recorded output and newly created
  ancestors, keeping existing empty directories. Remove directories only when
  empty; report cleanup failures and possible residual paths. Forced termination
  and power-loss recovery are outside this guarantee.
- Try `README.md` → `README.mbt.md`; if symlinking fails, copy identical content
  and warn that a copy was used. Copies do not stay synchronized. Copy failure
  triggers normal generation cleanup.
- After generation, initialize Git unless already inside a working tree.
  Missing/failing Git only warns. Do not stage, commit, add remotes, or enable hooks.

## Delivery acceptance

Both `moonx moonbit-community/moon-new hello --user tester` and
`moon install moonbit-community/moon-new` followed by `moon-new hello --user tester`
must work in separate clean locations, without package suffixes or target flags.
Verify help and missing-destination errors through both public entrypoints.
A published version, registry Wasm asset, and successful native install are required;
local installation alone does not establish public delivery.

Validate native and Wasm on macOS ARM64, Linux x86_64, and Windows x86_64.
Platform support follows the MoonBit toolchain; untested architectures are not
verified, and phase one does not promise separately released binaries.
Acceptance includes exact template inventory/bytes/link/Unix executable mode,
the cases above, and a generated project passing `moon check`, `moon test`
(zero starter tests), and `moon run cmd/main` with output `Hello`.
