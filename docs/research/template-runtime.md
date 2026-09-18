# Runtime template-engine investigation

Date: 2026-09-18. Scope: render the pinned `moon new` template in memory on Wasm and native; no dependency has been added to moon-new.

## Conclusion

`Lyllyl789/mustache@0.1.6` is the most promising runtime engine among the candidates inspected, but its low adoption and untidy published archive prevent calling it an established, polished dependency. Its runtime passed the fixed-template compatibility probes below. This is a candidate for explicit approval, not an adoption decision. `ryota0624/mustache` has more downloads but does not compile with the current toolchain. `jshsj124/moontemplate` loses supplementary Unicode during ordinary interpolation. `Yoorkin/splice` is not a template-language renderer.

## Candidates

Download counts are the live registry search snapshot collected on 2026-09-18, not unique users or proof of downstream adoption. The registry's cached documentation pages can show older totals.

| Package | Snapshot downloads | Evidence and fit |
| --- | ---: | --- |
| `Lyllyl789/mustache@0.1.6` | 24 | Mustache runtime with `render_string(String, Json) -> String raise MustacheError`; only core JSON import. Existing tests and focused compatibility probes pass on Wasm/native. |
| `ryota0624/mustache@0.0.6` | 94 | Dependency-free Mustache implementation, but current source fails to compile due to old syntax including `for {}`. Not usable unchanged with the current compiler. |
| `jshsj124/moontemplate@0.1.1` | 21 | Dependency-free Handlebars-style runtime. Existing tests pass, but an additional Unicode username case fails on both tested backends. |
| `Yoorkin/splice@0.1.2` | 1,274 | Replaces explicitly supplied line/column ranges. It does not parse `{{name}}` or resolve variables; callers would still implement that part. |

Primary package listings: [Lyllyl789/mustache](https://mooncakes.io/docs/Lyllyl789/mustache), [ryota0624/mustache](https://mooncakes.io/docs/ryota0624/mustache), [jshsj124/moontemplate](https://mooncakes.io/docs/jshsj124/moontemplate), [Yoorkin/splice](https://mooncakes.io/docs/Yoorkin/splice).

## Source and maintenance review

- Lyllyl789 source inspected at [`349b92228599e24c4a15e45f7294bad5902d83bb`](https://github.com/Lyllyl789/moon-mustache/tree/349b92228599e24c4a15e45f7294bad5902d83bb), committed 2026-08-16. MIT license. Its [manifest](https://github.com/Lyllyl789/moon-mustache/blob/349b92228599e24c4a15e45f7294bad5902d83bb/moon.mod) declares no external modules. The [package manifest](https://github.com/Lyllyl789/moon-mustache/blob/349b92228599e24c4a15e45f7294bad5902d83bb/mustache/moon.pkg) imports core JSON only. [CI](https://github.com/Lyllyl789/moon-mustache/blob/349b92228599e24c4a15e45f7294bad5902d83bb/.github/workflows/ci.yml) runs all backends on macOS, Linux, and Windows with MoonBit 0.10.7 pinned; the GitHub Actions API reported the latest runs successful. This is upstream CI evidence, not an independent three-platform rerun.
- Its [generated spec tests](https://github.com/Lyllyl789/moon-mustache/blob/349b92228599e24c4a15e45f7294bad5902d83bb/mustache/spec_test.mbt) cover the six core Mustache spec groups. The [generator](https://github.com/Lyllyl789/moon-mustache/blob/349b92228599e24c4a15e45f7294bad5902d83bb/gen_specs.py) reads upstream `master` without a pinned commit; it was inspected but not executed. This limits reproducibility of future fixture regeneration. The runtime also exposes cache, registry, catalog, audit, and batch APIs far beyond this project's needs; using only `render_string` is sufficient here.
- Ryota source inspected at [`16b0cc1f0914fe06efdba9d1f0b9b5ffe1d98aef`](https://github.com/ryota0624/moonbit-mustache/tree/16b0cc1f0914fe06efdba9d1f0b9b5ffe1d98aef), committed 2025-12-14. Apache-2.0; no declared external dependencies. No GitHub Actions runs were returned. Current compiler failure was observed in a temporary checkout without modifying its implementation.
- MoonTemplate source inspected at [`b5898dae9b605e53b550d3c6e6ada911bb5c2fd8`](https://github.com/jshsj124/MoonTemplate/tree/b5898dae9b605e53b550d3c6e6ada911bb5c2fd8), committed 2026-07-28. MIT; no external dependencies. [CI](https://github.com/jshsj124/MoonTemplate/blob/b5898dae9b605e53b550d3c6e6ada911bb5c2fd8/.github/workflows/ci.yml) uses Linux and the default backend. The [renderer](https://github.com/jshsj124/MoonTemplate/blob/b5898dae9b605e53b550d3c6e6ada911bb5c2fd8/render/render.mbt) slices strings one UTF-16 code unit at a time during HTML escaping, which is incompatible with supplementary characters; the failure below confirms the effect through its public API.
- Splice source inspected at [`2a222e07cfed5b267c818173ce7788657e675a07`](https://github.com/moonbit-community/splice/blob/2a222e07cfed5b267c818173ce7788657e675a07/splice.mbt), committed 2026-04-27. Apache-2.0. The API accepts precomputed `Replacement` ranges, not a variable context. Its higher download total does not make it a substitute template engine.

## Local executable evidence

Toolchain: `moon 0.1.20260916 (e4f45e4)`, `moonc v0.10.13+75bd53fc8-nightly (2026-09-15)`, macOS ARM64. All checkouts, archives, test probes, and logs are under a temporary directory. No user repository implementation, dependencies, or global installations were changed. All module/package manifests were inspected before builds; no build hooks or native stubs were found in these candidates.

| Test | Lyllyl789 | MoonTemplate |
| --- | --- | --- |
| Existing suite, Wasm | 161/161 passed | 37/37 passed |
| Existing suite plus 2 compatibility probes, Wasm | 163/163 passed | 38/39 passed |
| Existing suite plus 2 compatibility probes, native | 163/163 passed | 38/39 passed |

Both passing libraries emit deprecation warnings on the current nightly; neither result implies a warning-free `--deny-warn` build.

The first probe imports each library from a separate package and renders every path and all 14 ordinary file contents from the [official `e4f45e4` TOML](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/moonbuild/template/moon_new_template.toml). It compares exact strings, including terminal newlines, using `username = Milky2018`, `module = hello`, and `package = hello`. The oracle is fixed replacement of the three known markers; this is full snapshot-text coverage, not full Handlebars conformance or project filesystem generation. Both engines pass this probe.

The second probe checks a supplementary-plane Unicode letter, U+10400, in a username:

```text
input:    {{username}}/{{module}}\n
context:  username = 𐐀, module = hello
expected: 𐐀/hello\n
```

Lyllyl789 preserves the letter. MoonTemplate returns `/hello\n` on both backends, silently dropping the username. This matters because username validation is intended to accept Unicode letters.

Lyllyl789's [entry point](https://github.com/Lyllyl789/moon-mustache/blob/349b92228599e24c4a15e45f7294bad5902d83bb/mustache/mustache.mbt) compiles and renders without source normalization. Its [HTML escaping](https://github.com/Lyllyl789/moon-mustache/blob/349b92228599e24c4a15e45f7294bad5902d83bb/mustache/escape.mbt) handles `&`, `<`, `>`, quotes, and apostrophes. Those characters are excluded from the current project's variable values by name validation. The slash between `{{username}}/{{module}}` is literal template text and remains intact. Mustache and Handlebars have different larger languages, so this evidence only supports the pinned snapshot, not unrestricted Handlebars templates.

## Published archive review

The [Lyllyl789 0.1.6 archive](https://download.mooncakes.io/user/Lyllyl789/mustache/0.1.6.zip), SHA-256 `4c10a8caef57f51497aed4e0c7dc90268b1427233e992c1af9b38cc24601ef94`, contains unrelated nested `moonbit-statemachine` and `moonbit-workflow-engine` modules and a UTF-16 `test_err.mbt` scratch file. Runtime `.mbt` files and manifests match the inspected source checkout, but the generated Mustache spec test differs. After inspecting the archive manifests, I extracted it into a separate temporary directory and copied the same two public-API probes there. The published archive also passes 163/163 tests on Wasm and 163/163 on native. The unrelated nested modules and root scratch file did not prevent these tests; no claim is made that they are consumer dependencies. These extra files remain a concrete publication-hygiene concern; a clean upstream release would be preferable before adopting it.

The [MoonTemplate 0.1.1 archive](https://download.mooncakes.io/user/jshsj124/moontemplate/0.1.1.zip), SHA-256 `53fa6b61eb322a48a9aa6fc4f85ef5f714ca875f64a1d334ef34d33293e7aa7f`, matches the inspected repository's MoonBit source and manifests. The [Ryota 0.0.6 archive](https://download.mooncakes.io/user/ryota0624/mustache/0.0.6.zip) likewise matches its runtime code; the additional files are upstream Mustache JSON fixtures.
