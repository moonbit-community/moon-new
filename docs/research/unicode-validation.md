# Unicode validation libraries

Checked on 2026-09-18 against published archives and current upstream source.
The user subsequently accepted charclass's current semantics for phase one and
requested an upstream issue for the Unicode Alphabetic difference.

The user approved both `moonbit-community/charclass` and `moonbitlang/x/unicode`
as dependency options.

## Available APIs

The published `moonbitlang/x@0.5.5` archive contains `unicode`. Its public API
includes `CharClass`, `non_ascii_id_start`, `non_ascii_id_continue`, whitespace,
case conversion, and encoding helpers. It has no ready-made alphabetic or
alphanumeric predicate. The earlier conclusion that this package was absent,
based on an older cached dependency, was incorrect. Identifier membership is
not interchangeable with the reference username rule.
[Published module](https://mooncakes.io/docs/moonbitlang/x@0.5.5),
[current interface](https://github.com/moonbitlang/x/blob/39fcc98ebc6222715ba92e5aebf60bfc34951fb5/unicode/pkg.generated.mbti).

The published `moonbit-community/charclass@0.1.4` exposes
`unicode.is_alphanum(Char)`. It accepts general categories Letter and Number,
and depends on `moonbit-community/ucd@0.5.0`.
[Published module](https://mooncakes.io/docs/moonbit-community/charclass@0.1.4),
[classification implementation](https://github.com/moonbit-community/charclass/blob/9b806ba5d12d8f6d70abfa6267f10fa8a4d48642/unicode/classification.mbt).

## Compatibility boundary

Rust's `char.is_alphanumeric` accepts the Unicode Alphabetic property or a
numeric character. Alphabetic includes some combining marks that are neither
Letter nor Number. Therefore charclass is a practical existing classifier but
is not an exact replacement.
[Rust character documentation](https://doc.rust-lang.org/std/primitive.char.html#method.is_alphanumeric),
[official username validation](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/moon/src/cli/new.rs).

Local probes used `moon 0.1.20260916 (e4f45e4)` and the downloaded charclass
0.1.4 package on macOS ARM64:

| Input | Official `moon new --user` | charclass character result |
| --- | --- | --- |
| `a` followed by U+0345 COMBINING GREEK YPOGEGRAMMENI | Accepted | U+0345 rejected |
| `a` followed by U+0300 COMBINING GRAVE ACCENT | Rejected | U+0300 rejected |
| U+4E2D and U+10400 | Not probed through the CLI in this check | Both accepted |

The isolated charclass Unicode package passed its three existing tests plus
one compatibility probe under the Wasm target. Artifacts remain under
`/tmp/moon-new-unicode-package/`; no moon-new dependency was changed.

Decision: use charclass's existing predicate, plus dash and underscore checks,
without a local compatibility table or U+0345 special case. The product contract
now explicitly records the accepted difference. An upstream issue tracks the
broader Alphabetic-property support rather than blocking phase one.

Upstream tracking: [charclass issue #10](https://github.com/moonbit-community/charclass/issues/10).
