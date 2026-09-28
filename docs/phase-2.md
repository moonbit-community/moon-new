# Phase 2: Git repository templates

Status: implementation authorized; repository access and file selection are
implemented. Liquid is upgraded to `moonbit-community/liquid@0.2.0`;
CLI template generation remains in progress.

## Confirmed direction

Use [cargo-generate](https://cargo-generate.github.io/cargo-generate/) as the
design reference for Git repository templates. This selects a reference, not
full compatibility with its configuration, variables, filters, or hooks.

- Q13 (replaces Q5): Use `moon.new.json` with `include`, `exclude`, and `ignore`
  fields following cargo-generate's file-selection rules. Do not use a special
  `.liquid` suffix to select files or rename output.
- Q6: Provide only fixed built-in variables; templates cannot declare custom
  variables.
- Q7: Do not support template scripts or generation hooks.
- Q8/Q12: Match default-template project naming and credential resolution.
  Expose only `username` (the username) and `module` (the short project name).
  The full module identity is `{{username}}/{{module}}`. Do not expose `package`.
- Q9: Expand variables in file and directory names, including paths of files
  whose contents are copied unchanged.
- Q10: Fail on output path collisions. Do not prefer either source or overwrite
  one with the other.
- Q11: Fail on unknown variables and identify the source template and variable
  in the diagnostic.
- Q14/Q30: Accept public HTTPS Git addresses, local Git repository paths, and
  `owner/repo` shorthand for public GitHub repositories. Keep phase two to
  anonymous remote access; defer SSH and private remote repositories.
- Q15: Support the default branch and explicit branch, tag, or commit selection.
  Follow `moon install --help` for option names: `--branch`, `--tag`, and `--rev`
  (commit hash), with mutually exclusive selectors. The `owner/repo` shorthand
  means GitHub here, whereas bare package paths in `moon install` select registry
  packages.
- Q16: For local Git repositories, use committed contents, defaulting to HEAD;
  allow the same branch/tag/commit selectors. Ignore working-tree changes and
  untracked files.
- Q17: Allow a repository subdirectory to be selected as the template root.
  The subdirectory's contents populate the destination directly.
- Q18: Select it with `--subdir <PATH_IN_REPO>`, not a second positional argument.
  Without `--subdir`, use the repository root.
- Q19: Read `moon.new.json` only from the selected template root. If absent, use
  default rules; do not search ancestors or merge configurations.
- Q20: Preserve symbolic links as symbolic links in generated output.
- Q21: Do not support submodules. Fail when a submodule occurs within the
  selected template scope and is not excluded by `ignore`; do not fetch it
  recursively or silently emit an empty directory.
- Q22: Expand built-in variables in symbolic-link target text.
- Q23: If link creation fails, try to copy the target as an ordinary file or
  directory and warn that a copy was used.
- Q24: Allow external and dangling link targets. Normal link preservation must
  not traverse or copy their targets.
- Q25: Limit link-copy fallback to this generation's project contents, after
  variable expansion. External, missing, or cyclic fallback targets fail
  creation and trigger rollback.
- Q30 (replaces Q26): Do not add repository authentication: no credential
  helpers, token settings, login prompts, or authenticated HTTP adapter.
  Report remote access failures normally. Default-template username resolution
  from MoonBit credentials is separate and retains its existing behavior.
- Q27: Do not support Git LFS. Fail when a file required in the generated output
  uses LFS; do not silently output a pointer file.
- Q28: Use the current bit project through its `mizchi/bit_*` library modules,
  not the deprecated `mizchi/git` package or the bit CLI. Select exact modules
  and versions during implementation design.
- Q29: Do not depend on a locally installed Git executable, including
  `git credential` and `git-upload-pack`. Avoid library defaults that invoke
  local Git. The earlier allowance for external `ssh` does not add SSH support
  to Q30's reduced scope.
- Q31: Reject unknown fields in `moon.new.json` with a diagnostic naming the
  field, rather than silently ignoring them.

```text
moon-new <PATH> --template <SOURCE> [--subdir <PATH_IN_REPO>]
  [--branch <BRANCH> | --tag <TAG> | --rev <COMMIT>]
  [--user <USER>] [--name <NAME>] [-q | --quiet]
```

## Template configuration

`moon.new.json` is optional and contains string-array fields `include`, `exclude`,
and `ignore`. The template-root configuration itself is omitted from output.

- With neither `include` nor `exclude`, render all ordinary file contents.
- If `include` is present, render only matching contents; `include: []` renders
  none. If `exclude` is also present, warn and ignore it.
- Without `include`, copy contents matching `exclude` unchanged and render the
  rest. Files not selected for rendering remain in the output.
- `include` and `exclude` use Gitignore-style patterns against template-relative
  source paths before variable substitution. Content selection does not disable
  variable substitution in paths.
- `ignore` contains literal template-relative source paths, not patterns.
  Omit matching files or whole directory subtrees before rendering; missing
  entries have no effect.
- Selected contents must be valid UTF-8; otherwise creation fails. Authors must
  use `include` or `exclude` to keep binary files out of content rendering.
  Unrendered contents are copied as bytes.

These rules follow cargo-generate
[`188faa15`](https://github.com/cargo-generate/cargo-generate/tree/188faa15ffd47986729019426750c35dda7cc85a):
[matching](https://github.com/cargo-generate/cargo-generate/blob/188faa15ffd47986729019426750c35dda7cc85a/src/include_exclude.rs#L18-L75),
[ignoring](https://github.com/cargo-generate/cargo-generate/blob/188faa15ffd47986729019426750c35dda7cc85a/src/ignore_me.rs#L23-L51),
and [content processing](https://github.com/cargo-generate/cargo-generate/blob/188faa15ffd47986729019426750c35dda7cc85a/src/template.rs#L220-L263).
Its special `.liquid` handling and Cargo-specific metadata exclusions do not apply.

## Implementation progress

- `repository` reads local loose/packed objects and refs through bit, and fetches
  public HTTPS repositories through an injected official MoonBit HTTP client.
  It preserves committed bytes, executable modes, link targets, and gitlinks;
  selects a branch, tag, full commit ID, and/or subtree without a checkout.
- `template.select` reads the selected root's configuration, selects rendering
  versus byte copying, applies literal omissions, and rejects required LFS
  pointers, submodules, and non-UTF-8 rendered contents.
- Git initialization also uses bit. Fresh repositories start on `main`; this
  library path does not read global Git configuration or `GIT_CONFIG_*` process
  overrides. Existing parent working trees are reused, and initialization
  failures remain warnings after project files are generated.
- The private `Disk` adapter implements the filesystem traits required by bit.
  It is not an injectable project-generation filesystem. Its timestamp method
  explicitly fails: the object/ref operations used here do not request mtimes.

Pending: Git-template rendering of contents/paths/link
targets, output-path validation and collisions, CLI options, binary output,
directory-link fallback/rollback, and end-to-end template generation acceptance.
The existing CLI still creates only the bundled default template.

Phase-one behavior is documented in [phase-1.md](phase-1.md), with Git command
invocation superseded by the library initialization described above.

## Dependency findings

The former dependency, `bobzhang/liquid` 0.1.1, returned an `[ERROR: ...]` string
under its `Strict` policy instead of a structured failure. Following the user's
decision to wait for publication, it has been replaced with
`moonbit-community/liquid@0.2.0`. Its `compile` and `Template::render` APIs return
`Result` values with diagnostics. The bundled renderer now propagates these as
`TemplateError`, including the source path, phase, code, message, and available
UTF-16 offset. No unpublished source is vendored and error-like output text is
not interpreted as a failure. Q11 still requires Git-template integration.

The current implementation uses `mizchi/bit_lib`, `bit_protocol`, `bit_repo`,
`bit_object`, and `bit_types` version 0.48.0. Local and HTTPS
repository tests run on native and Wasm; network smoke tests are opt-in via
`MOON_NEW_TEST_REMOTE=1`. Integration fixtures use Git only in test setup.

The user approved implementing pattern matching locally after review found
that bit_ignore 0.48.0 lacks character classes and general escapes. File
selection uses a local matcher with closest-path precedence, character classes,
escapes, directory rules, `**`, and glob alternations. As with cargo-generate,
literal braces in source names must be escaped in patterns; JSON requires an
additional backslash escape (for example `"\\{\\{module\\}\\}.txt"`).

`mizchi/git` 0.2.0 is marked deprecated in the registry in favor of `mizchi/bit`.
Its repository redirects to [bit-vcs/bit](https://github.com/bit-vcs/bit).
The current source splits reusable libraries into `mizchi/bit_*` modules.
Inspect the selected modules and versions before adding dependencies; the
successor CLI is not a substitute for library calls.

Source inspection at `bit-vcs/bit` commit
`2681c3bc815d01aa56e678f45eb98e268c052481` found integration gaps (not runtime
validation): native HTTP defaults call `git credential fill` with terminal
prompts disabled; local/SSH transports invoke `git-upload-pack`/`ssh`; Wasm HTTP
requires explicit client injection and has no ready-made SSH process transport.
Under Q30, SSH and authentication are out of scope. Anonymous HTTP injection
and direct local object/ref access are now implemented and tested on native and
Wasm without Git on PATH. Windows absolute gitdir handling is corrected at the
library boundary; execution on Windows still requires CI validation.

Pattern semantics were compared with cargo-generate's pinned `ignore` 0.4.33
and `globset` 0.4.20 using a temporary Rust oracle (1,296 combinations), followed
by focused regressions for review findings. Committed tests are all MoonBit.

Validation on macOS: warning-free native/Wasm checks and builds, 38 native
tests, 13 Wasm tests, 17 CLI tests against the Wasm executable, and anonymous
HTTPS smoke tests on both backends. Standards and spec review findings were
fixed and covered by focused regressions. Other operating systems await CI.
