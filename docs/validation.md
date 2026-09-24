# Validation

Last code validation: **2026-09-24, macOS ARM64**. Moon `0.1.20260920 (914d7da)`;
moonc `v0.10.14+7d59c7ec9 (2026-09-18)`.
Dependencies: async 0.22.1, x 0.5.5, charclass 0.1.4 (ucd 0.5.0), Liquid 0.1.1.

| Check | Recorded result |
| --- | --- |
| Native/Wasm check with `--deny-warn` | Passed |
| Native tests, including CLI and package acceptance | 24 reported passed |
| Wasm tests | 6 reported passed |
| CLI acceptance per backend, using a native harness | 17 reported passed each |
| Archive assets, regeneration, local installation | Passed |
| Generated project check/test/run | Passed; zero starter tests; output `Hello` |
| `moon info`, `moon fmt`, whitespace checks | Passed |

Windows-only CLI and path-joining cases do not execute their assertions on macOS;
the runner counts these as passed. These totals do not establish Windows support.
Reproduction commands are in [README](../README.md#development).

## Evidence and limits

- `tests/fixtures/official.json` independently captures Moon `e4f45e4` output
  for `tester/hello`. It checks inventory, bytes, README link/copy, and Unix hook
  mode. Windows link checks compare resolved destinations; Unix also checks
  literal link text. Original template whitespace is intentionally preserved.
- Real filesystem tests cover ordinary creation, filename-limit rollback,
  existing empty-directory preservation, and `missing/../existing` rejection.
  Successful rollback preserves the original `OSError` type.
- CLI tests cover names, credentials, destination rules, symlinks, Unix umask,
  Git reuse/failure, quiet mode, full stable diagnostic text, warning-before-error
  order, and token secrecy. Missing Git uses an empty child PATH; initialization
  failure uses Git's invalid default-branch configuration. OS reason text varies.
- The package test verifies all 14 assets/constants, extracts the archive,
  removes generated constants, installs locally, and checks regeneration,
  installed command naming, and a generated project. This is not publication.
- Removing the filesystem adapter also removed injected partial-write,
  symlink/copy, chmod, cleanup-failure, and file-race tests. Those forced failure
  paths are no longer exercised. README fallback and rollback remain implemented.
- Standards/Spec reviews found no remaining actionable issues after correcting
  `..` destination checks and Windows drive-relative joins. Diagnostic cleanup
  was reviewed against `cd0c61a`. No general Liquid conformance is claimed.

## Remaining acceptance

The CI workflow defines native/Wasm jobs for macOS ARM64, Linux x86_64, and
Windows x86_64. Linux/Windows runs and hosted CI execution remain unverified;
the repository has no configured remote. No module version has been published.
Public `moonx moonbit-community/moon-new` and `moon install moonbit-community/moon-new`
acceptance awaits publication, registry Wasm availability, and actual runs.
