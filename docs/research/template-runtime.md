# Runtime alternatives

Historical check: **2026-09-18**, macOS ARM64, Moon `e4f45e4`,
moonc `v0.10.13+75bd53fc8-nightly`. These candidates were not adopted;
the user subsequently chose [Liquid](template-liquid.md).

| Candidate / inspected source | Native and Wasm evidence |
| --- | --- |
| [Lyllyl789/mustache 0.1.6](https://github.com/Lyllyl789/moon-mustache/tree/349b92228599e24c4a15e45f7294bad5902d83bb) | 161 upstream tests + 2 compatibility probes passed |
| [jshsj124/moontemplate 0.1.1](https://github.com/jshsj124/MoonTemplate/tree/b5898dae9b605e53b550d3c6e6ada911bb5c2fd8) | 37 upstream tests passed; combined probes yielded 38/39 |
| [ryota0624/mustache 0.0.6](https://github.com/ryota0624/moonbit-mustache/tree/16b0cc1f0914fe06efdba9d1f0b9b5ffe1d98aef) | Compilation failed on old syntax, including `for {}` |
| [Yoorkin/splice 0.1.2](https://github.com/moonbit-community/splice/blob/2a222e07cfed5b267c818173ce7788657e675a07/splice.mbt) | Operates on supplied ranges; no variable/template parser |

Both tested renderers reproduced all 14 ordinary files and paths of the
[official snapshot](https://github.com/moonbitlang/moon/blob/e4f45e4/crates/moonbuild/template/moon_new_template.toml).
A separate `{{username}}/{{module}}\n` probe with username `𐐀` exposed
MoonTemplate dropping that supplementary character; Lyllyl789 preserved it.
These are snapshot-text checks, not general Handlebars conformance or file generation.

Lyllyl789's published archive also passed 163/163 tests on both backends but
contained unrelated nested modules and a UTF-16 scratch file. Its spec generator
reads unpinned upstream `master`; it was inspected, not executed. Low adoption,
archive hygiene, and deprecation warnings limited a maturity recommendation.
Upstream CI covered three OSes, but local verification was macOS only.
