# Unicode validation decision

Historical check: **2026-09-18**, macOS ARM64, Moon `e4f45e4`.
The user approved charclass and x/unicode as options, then accepted charclass's
existing semantics without a local compatibility table or U+0345 special case.

- [x 0.5.5 unicode](https://github.com/moonbitlang/x/blob/39fcc98ebc6222715ba92e5aebf60bfc34951fb5/unicode/pkg.generated.mbti)
  exists and exposes identifier character sets, but no ready-made alphanumeric
  predicate. Identifier membership does not match the username rule.
- [charclass 0.1.4](https://github.com/moonbit-community/charclass/blob/9b806ba5d12d8f6d70abfa6267f10fa8a4d48642/unicode/classification.mbt)
  uses Letter/Number categories and depends on ucd 0.5.0. Rust's
  [alphanumeric predicate](https://doc.rust-lang.org/std/primitive.char.html#method.is_alphanumeric)
  additionally accepts Alphabetic-property combining marks.

| Probe | Official CLI | charclass |
| --- | --- | --- |
| `a` + U+0345 | Accepted | Combining mark rejected |
| `a` + U+0300 | Rejected | Combining mark rejected |
| U+4E2D, U+10400 | Not CLI-probed in this check | Accepted |

Three upstream tests plus one compatibility probe passed on Wasm. Use
`unicode.is_alphanum` plus `-`/`_`, requiring a nonempty username.
Track the Alphabetic gap in [charclass #10](https://github.com/moonbit-community/charclass/issues/10);
it does not block phase one.
