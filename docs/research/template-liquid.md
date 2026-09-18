# Liquid runtime engine assessment

Checked on 2026-09-18. After reviewing these findings, the user explicitly
selected `bobzhang/liquid` and expects an imminent upstream update. The findings
below remain evidence about 0.1.1, not a claim about a future release. Recheck
the published version and required behavior before integration.

## Package and maintenance

`moon view bobzhang/liquid` reported version **0.1.1**, **37 downloads**, Apache-2.0, and publication on **2026-09-10**. The downloaded manifest has no external dependencies or target restrictions. Its archive contains one root library, a `cmd/main` demo, documentation, tests, and `.liquid` examples; no unrelated nested module manifests or build hooks were found. [Registry](https://mooncakes.io/docs/bobzhang/liquid@0.1.1), [repository](https://github.com/moonbit-community/liquid-moonbit).

Repository HEAD was `79bdad33f5567456fe154d42d573ca714cd45cee`, dated September 8, with a compiler compatibility fix. CI runs on Ubuntu with `moon check --deny-warn` and `moon test --target all`; its latest run succeeded. This is useful maintenance evidence, but not proof of three operating systems. [CI source](https://github.com/moonbit-community/liquid-moonbit/blob/79bdad33f5567456fe154d42d573ca714cd45cee/.github/workflows/ci.yml), [successful run](https://github.com/moonbit-community/liquid-moonbit/actions/runs/34188719914).

## Fit and source concerns

The public API directly parses a string into a `LiquidTemplate`, supplies values through `LiquidContext`, and renders at runtime. Basic `{{username}}` syntax fits the existing template markers and embedded text workflow without a code-generation step. [API interface](https://github.com/moonbit-community/liquid-moonbit/blob/79bdad33f5567456fe154d42d573ca714cd45cee/pkg.generated.mbti).

However, several advertised language features are placeholders in the published implementation: parsing `raw` inserts the hardcoded text `{{ not_processed }} liquid code`; `capture` inserts `CAPTURED_CONTENT`; `style` inserts `CSS_CONTENT`. Strict error policy returns an error marker string rather than raising an error. Existing tests assert some of these placeholder behaviors. These are substantive quality concerns even though basic substitution works and all upstream tests pass. [Parser and renderer implementation](https://github.com/moonbit-community/liquid-moonbit/blob/79bdad33f5567456fe154d42d573ca714cd45cee/liquid.mbt), [upstream tests](https://github.com/moonbit-community/liquid-moonbit/blob/79bdad33f5567456fe154d42d573ca714cd45cee/liquid_test.mbt).

## Local verification of the published package

Environment: macOS ARM64, `moon 0.1.20260916 (e4f45e4)`, `moonc v0.10.13+75bd53fc8-nightly`. Artifacts are under `/tmp/moon-new-liquid.acoU5U/`. No moon-new dependencies or global executable installations were changed.

| Test | Wasm | Native |
| --- | --- | --- |
| Published upstream tests | 360/360 passed | 360/360 passed |
| Three phase-one markers, Unicode value, preserved newlines | Passed | Passed |
| Independent raw-block preservation probe | Failed | Failed |

The failing public-API probe rendered `{% raw %}unique-literal{% endraw %}` as `{{ not_processed }} liquid codeunique-literal`, rather than `unique-literal`. This confirms the source concern with an input distinct from the upstream examples. This was a bounded fit review, not a complete Liquid conformance audit, and did not test the complete official moon template snapshot.

## Assessment before the user's selection

Its packaging is small and straightforward, and its runtime interface matches the desired integration shape. Nevertheless, the placeholder implementations and a basic independent feature failure prevent recommending it as a generally good-quality Liquid engine. A narrow substitution-only use is technically possible but would need explicit acceptance of the restricted scope; it should not be selected merely because the upstream suite has 360 passing tests.
