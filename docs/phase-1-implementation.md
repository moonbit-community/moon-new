# Phase 1 Implementation Plan

Status: implementation is present. Local validation and remaining delivery
checks are recorded in [validation.md](validation.md). This document preserves
the agreed mechanisms and acceptance sequence.

The product contract and acceptance criteria are in [phase-1.md](phase-1.md).
This document records implementation work and verification steps separately.

## Distribution constraints

- Change this module's identity from `Milky2018/moon-new` to
  `moonbit-community/moon-new` when implementation begins.
- Make the module's root package executable. Bare module selectors in both
  `moonx` and `moon install` address the root package, not `cmd/main`.
- Support `wasm` and `native`; keep `wasm` as the preferred target. `moonx`
  uses a registry Wasm asset by default, while installation builds native.
- The root package's installed command must be `moon-new` (`moon-new.exe` on
  Windows). Adjust this tool's current `cmd/main` entrypoint accordingly.
- Keep the generated default project's `cmd/main` layout unchanged.

Source references:

- [Registry execution through moonx](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/moon/src/cli/moonx.rs)
- [Package selection, backend, and binary naming for installation](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/moon/src/cli/install_binary.rs)
- [Registry Wasm artifact retrieval](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/mooncake/src/registry/client.rs)
- [Filesystem APIs](https://github.com/moonbitlang/async/blob/48f72f7683531883892211288ebd9f0476e61c6a/src/fs/pkg.generated.mbti)
- [Process APIs](https://github.com/moonbitlang/async/blob/48f72f7683531883892211288ebd9f0476e61c6a/src/process/pkg.generated.mbti)

## Agreed implementation constraints

- Reuse existing libraries where practical, preferring official MoonBit libraries.
  Confirm with the user before selecting any non-official dependency.
- Organize code into ordinary packages by responsibility. Avoid `internal`
  packages where practical; the earlier proposed `internal/project` layout is
  not an accepted design.

## Agreed dependencies and package layout

- Use official `moonbitlang/core/argparse` for command-line parsing,
  `moonbitlang/async/fs` for filesystem operations,
  `moonbitlang/async/process` for Git processes, and `moonbitlang/x/path`
  for path operations. JSON, Unicode, and Liquid selections are recorded below.
- Keep `main` and the CLI implementation in the executable root package,
  including argument parsing, output routing, and exit codes. Do not create a
  separate `cli` package or retain this tool's `cmd/main` entrypoint.
- Use `project` for credentials, name validation, creation, rollback, and Git.
- Use `template` for embedded assets, the template inventory, and Liquid
  rendering. `project` uses `template`; the root package invokes `project`.
- Expose only interfaces needed across these package boundaries. Do not design
  a general project-generation framework in phase one.

## Agreed template storage and embedding

- Keep original template files as the authoritative source, rather than
  hand-maintaining their contents as MoonBit string literals.
- Use `dev_build` to embed these assets into generated MoonBit source.
- Keep generated source as derived data, not a separately editable template.
- Commit generated `.mbt` files alongside their source assets. Development
  builds run the embedding rules; dependency builds use committed outputs.
- `moon install` builds the selected application as a root module and runs its
  `dev_build` rules. Ship both raw assets and generated sources: a missing raw
  input can fail installation even when its generated output is present.
- Use the toolchain's `:embed --text` rule command, with explicit constant names
  and declared input/output paths. The toolchain expands `:embed` into its own
  embedding tool without requiring a custom generator script.
- Preserve hidden template assets explicitly in the package archive; declaring
  a `dev_build` input does not automatically override packaging exclusions.
- Check generated-source consistency and inspect the package archive in CI.
- Store authoritative files under `template/assets/`, with generated embedding
  source in the `template` package. Generated filenames and constant names are
  implementation details and must map unambiguously to their source assets.
- Represent the fixed template inventory as a small typed MoonBit list with
  output paths, embedded contents, symbolic-link targets, and executable flags.
  Do not add a JSON/TOML manifest parser or scan directories at runtime.

## Agreed template engine

The user requested a survey of community engines before choosing the rendering
mechanism. [The comparison](research/template-engines.md) records live download
counts, source review, and isolated runtime checks.

- Use `bobzhang/liquid` for runtime rendering of embedded template text.
  The user explicitly selected this non-official dependency after the review.
- Keep the original template assets and the agreed `dev_build :embed --text`
  flow. Do not replace Liquid with a custom three-token renderer.
- The user expects an imminent upstream update. Recheck the published version
  and relevant rendering behavior when implementation begins; an expected fix
  is not an already verified fix. The selection does not pin version 0.1.1.
- Phase one still uses only the fixed official template. General Liquid
  conformance and the future Git-template language are outside this decision.

## Agreed Unicode validation

- The user explicitly approved `moonbit-community/charclass` and
  `moonbitlang/x/unicode` as acceptable libraries. Using charclass does not
  require repeating the third-party approval question.
- Current published `moonbitlang/x@0.5.5` does contain `unicode`; the earlier
  negative conclusion from a cached dependency was incorrect. Its identifier
  character sets do not directly implement Rust's alphanumeric predicate.
- `charclass@0.1.4` exposes `unicode.is_alphanum`, based on Unicode general
  categories Letter and Number. This differs from the official Rust predicate
  for alphabetic combining marks, including U+0345.
- Use charclass's `unicode.is_alphanum` plus explicit dash and underscore
  checks, with a nonempty username requirement. The user explicitly accepted
  the current category-based semantics, including the U+0345 difference.
- Track the Unicode Alphabetic gap in
  [charclass #10](https://github.com/moonbit-community/charclass/issues/10).
  Do not maintain a local Unicode table, add a special case for U+0345, or
  block phase one on this difference.

See [the Unicode validation findings](research/unicode-validation.md).

## Agreed credential parsing

- An explicit `--user` skips credential-directory lookup and file reading.
- Otherwise, use `MOON_HOME/credentials.json` when `MOON_HOME` is set. If it
  is unset, use `HOME/.moon/credentials.json` on Unix or
  `USERPROFILE/.moon/credentials.json` on Windows. Read these values with
  `core/env`; do not add OS-level home-directory bindings.
- Preserve reference environment-value handling: a present `MOON_HOME` is
  used even if empty or relative; Unix accepts a present `HOME`, while Windows
  requires a nonempty `USERPROFILE`. Do not introduce tilde expansion.
- If the environment cannot establish a credential directory, warn and use
  `username`. This intentionally omits the official Rust library's system
  user-directory fallback and does not fail project creation.
- Use `moonbitlang/core/json`, with its standard strict JSON syntax.
- Do not add JSON5, a third-party JSON parser, or a custom lenient JSON adapter.
- Validate the credential fields separately: `token` is a required string;
  `username` is an optional string, with missing or null treated as absent.
- Malformed JSON or invalid credential fields follow the reference warning and
  fallback path. A valid document without a username uses the default username.
- Comments and trailing commas accepted by official `serde_json_lenient` are
  an intentional unsupported extension here, explicitly accepted by the user.
- Retain the reference handling of file access: a missing credentials file
  warns and falls back; failure to open an existing file falls back silently;
  errors while reading/parsing opened content warn and fall back. Do not write
  or modify credentials as part of project creation.

## Agreed direct-write strategy

The official generator writes directly into the destination. It creates parent
directories recursively, opens each ordinary file with `File::create` (which
can truncate an existing file), renders its content, and writes it. It processes
entries sequentially, then attempts Git initialization. It has no staging
directory, creation journal, or rollback; a fatal generation error returns
immediately and leaves earlier output in place.

This project uses direct sequential writes with a local record of newly created
paths for reverse-order cleanup, rather than generating in a staging directory.

1. Parse arguments, read credentials, and validate names.
2. Render output paths and contents in memory before filesystem mutation.
3. Verify that the destination is absent or empty.
4. Create required directories and files sequentially. Open files exclusively
   with `CreateNew`; do not overwrite paths that appeared after the check.
5. Record each file immediately after successful creation, before writing its
   contents, so a later write failure still leaves a tracked cleanup target.
   Record directories created by this invocation as well.
6. On generation failure, remove recorded files and then remove created
   directories in reverse order, only when empty. Retain an originally existing
   empty destination. Do not recursively erase an untracked directory tree.
7. After all template output is complete, attempt Git initialization according
   to the agreed warning-only failure policy.

Keep these records local to the creation operation; do not introduce a generic
transaction framework. This strategy was explicitly accepted after comparison
with the official generator.

## Agreed path handling

- Reject a destination that is itself a symbolic link, including a dangling
  link. Parent-directory symbolic links may be followed normally.
- Create missing ancestors as needed and record only directories created by
  this invocation. Cleanup removes such directories only when they are empty.
- Preserve operating-system path traversal semantics. Do not lexically collapse
  `..` in a way that changes traversal through symbolic links.
- The destination still must be absent or completely empty; the acceptance of
  parent-directory links does not permit a nonempty destination.

## Agreed Git execution and diagnostics

- Launch system Git with an argument array using `async/process`, without a
  shell. Inherit the process environment and use the destination as Git's
  working directory.
- Capture process output. Normal mode displays initialization output; quiet
  mode suppresses successful initialization output. A Git failure is reported
  as a warning and does not roll back a successfully generated project.
- Write help and success messages to stdout; warnings and errors to stderr.
- Exit with `0` on success, `1` on project-creation failure, and `2` on command
  argument errors. A Git warning still results in success.

## Agreed failure-testing seam

- Test normal creation through temporary directories and the real filesystem.
- Allow the creation operation to receive a small filesystem-operation
  interface. Production supplies the real implementation; tests supply a
  substitute that fails a selected operation deterministically.
- Use this seam to exercise partial-write rollback and README symbolic-link
  fallback, including failure of the fallback copy and of cleanup itself.
- Keep the interface scoped to operations required by project creation; do not
  introduce a general virtual filesystem or a dependency-injection framework.
- Do not add production CLI options or environment variables for fault injection.

## Platform API findings

- The approved async library exposes runtime host information through
  `async.platform` on both native and Wasm. Use host information rather than
  compile-time native platform conditions for a portable Wasm executable.
- `async/fs.chmod` can set the hook's Unix executable permissions; its Windows
  implementation is unsupported. Skip that operation on Windows. Retain the
  reference behavior of warning, rather than rolling back, if Unix permission
  setting fails.
- No home-directory helper was found in the inspected public async, x/sys, or
  core/env interfaces. Official Moon uses Rust `home` 0.5.9, which has OS-level
  fallbacks beyond environment variables. The user accepted the environment-only
  lookup and warning/default-username fallback described above.

## Compatibility implementation and verification

- Use a narrow helper for reference `file_stem` behavior where x/path's
  basename or extension operations differ; verify it against official output.
  This is compatibility glue for the already agreed naming contract, not a
  replacement path library.
- Verify template content and filename rendering against fixtures captured
  from the pinned official generator, recording the source revision and
  toolchain. Do not derive the expected output from the Liquid renderer under
  test. Preserve empty files and exact trailing-newline behavior.

Recheck the selected dependency versions and record the toolchain used during
implementation. If an API gap requires a new non-official dependency or a change
to the agreed behavior, explain the concrete gap before changing the design.

## Work sequence

Follow the agreed mechanisms above throughout this sequence.

1. Establish the executable root package and command-line contract.
   Verify both backend builds, help, argument errors, and installed command
   naming using an isolated local installation directory.
2. Add the fixed default-template snapshot and official naming behavior.
   Compare generated files against the inspected official output for explicit
   and inferred names; test credential parsing with isolated fixtures.
3. Implement destination eligibility, generation, and cleanup.
   Exercise nonexistent, empty, and populated destinations and deterministic
   failure cases through the executable's observable behavior.
4. Add README fallback, platform-specific permissions, and Git initialization.
   Test ordinary operation and controlled failures, including quiet-mode output.
5. Complete the three-platform CI matrix for Wasm and native.
   Validate generated projects with the MoonBit toolchain, then run `moon info`
   and `moon fmt` and review the resulting interfaces and changes.
6. Deliver through Mooncakes and verify the public entrypoints.
   After implementation and local/CI acceptance, publish the intended version,
   verify registry Wasm availability, and exercise the exact public `moonx`
   and `moon install` commands against temporary destinations.

## Verification boundaries

- Build success is not proof of file cleanup, Git behavior, or registry delivery.
- Upstream library platform support does not replace this project's own matrix.
- Do not claim public entrypoint acceptance from a local executable alone.
- Implementation has proceeded after the design interview. Publishing is still
  pending; do not interpret local package installation as registry delivery.
