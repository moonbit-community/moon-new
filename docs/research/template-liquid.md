# Liquid 0.1.1 assessment

Historical check: **2026-09-18**, macOS ARM64, Moon `e4f45e4`,
moonc `v0.10.13+75bd53fc8-nightly`. The user selected this engine;
these findings do not describe later releases.

[Published package](https://mooncakes.io/docs/bobzhang/liquid@0.1.1): Apache-2.0,
no external dependencies or target restrictions, compact archive without nested
modules/build hooks. Inspected [source](https://github.com/moonbit-community/liquid-moonbit/tree/79bdad33f5567456fe154d42d573ca714cd45cee)
had a successful Ubuntu CI run, not independent three-platform verification.

| Probe | Native and Wasm result |
| --- | --- |
| Published upstream suite | 360/360 passed |
| Three phase-one variables, Unicode, newlines | Passed |
| Independent raw-block preservation | Failed |

`{% raw %}unique-literal{% endraw %}` produced
`{{ not_processed }} liquid codeunique-literal`. The inspected implementation also
hardcodes `capture`/`style` output and returns a marker rather than raising under
strict error policy. See [implementation and tests](https://github.com/moonbit-community/liquid-moonbit/tree/79bdad33f5567456fe154d42d573ca714cd45cee).

The runtime API fits embedded text rendering. These initial probes did not cover
the full official snapshot or general Liquid conformance; subsequent project
fixture coverage is recorded in [validation](../validation.md).
