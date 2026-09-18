# Phase-one validation

Validation date: 2026-09-18. Platform: macOS ARM64.

## Recorded environment

- Moon: `0.1.20260916 (e4f45e4)`.
- Moonc: `v0.10.13+75bd53fc8-nightly`.
- Dependencies: async 0.22.1, x 0.5.5, charclass 0.1.4 (ucd 0.5.0),
  bobzhang/liquid 0.1.1. Liquid 0.1.1 was still the newest published version at
  implementation time. No general Liquid feature conformance is claimed.
- Template fixture: `tests/fixtures/official.json`, captured by the pinned
  official `moon new` with username `tester` and name `hello`. It is independent
  of the Liquid rendering implementation.

## Checks

| Check | Result |
| --- | --- |
| Native and Wasm typechecking with `--deny-warn` | Passed |
| MoonBit tests, native | 11 passed |
| MoonBit tests, Wasm | 11 passed |
| CLI acceptance, native | 12 passed, 1 Windows-only case skipped |
| CLI acceptance, Wasm | 12 passed, 1 Windows-only case skipped |
| Packaged assets, regenerated constants, local installation | Passed |
| Generated project check/test/run | Passed; 0 starter tests; output `Hello` |
| `moon info`, `moon fmt`, staged whitespace check | Passed |

The MoonBit suite includes a Windows-only guarded-drive test which returns
without exercising its assertions on macOS. The Windows path fixes have source
review and CI tests, not a claimed local Windows execution. Raw upstream
trailing whitespace is preserved through narrow `.gitattributes` exceptions.

Git initialization failure was exercised through Git's own invalid default-branch
configuration; absent Git through an empty child `PATH`. Both keep generated
files and return success with warnings. Native and Wasm also pass the regression
for a missing ancestor followed by `..` resolving to a populated destination.

## Review

Baseline: `cade6e9a35230b6757ff8a222b411057ff2f86f0`. The code-review skill's two
independent reviewers inspected staged changes against that initial commit.
The local spec files were used directly; no external issue tracker was needed.

### Standards

No actionable documented-standard violations or judgement-based smells found.
The approved filesystem seam, package boundaries, and bundled template storage
match the agreed constraints.

### Spec

The first pass found two path-handling defects: ancestors exposing a populated
or symlink destination through `..`, and Windows drive-relative path joining.
Both were fixed and covered by regression tests. Follow-up review found no
remaining actionable spec issues. Final Wasm validation rebuilt the artifact
before running the regression tests.

## Packaging evidence

The archive check packages the module, checks all 14 source assets and generated
constants, extracts the archive into a temporary directory, deletes generated
constants, and installs from that source. It then verifies the installed command
name and checks, tests, and runs a generated project. This exercises application
`dev_build` behavior and does not publish to Mooncakes.

The CI workflow defines macOS ARM64, Linux x86_64, and Windows x86_64 jobs, each
covering native and Wasm. Tests use the real filesystem and external CLI. The
approved filesystem seam injects partial writes, symlink/copy failures, cleanup
failures, and an independently created file after preflight.

## Remaining delivery checks

- Linux and Windows execution have not been performed locally.
- The repository has no configured Git remote, so the workflow has not been run
  on a hosted CI service during this implementation.
- No module version has been published. The exact public `moonx
  moonbit-community/moon-new` and `moon install moonbit-community/moon-new`
  entrypoints remain unverified until publication and registry Wasm availability.
