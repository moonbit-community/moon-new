# Precompiled template engine assessment

Checked on 2026-09-18. This is research, not a dependency decision.

## Published packages and maintenance

`moon search template` reported **4,228 downloads** for `justjavac/template@0.1.1` and **58** for `justjavac/template_codegen@0.1.3`. These are registry counters at one point in time, not unique users or production-adoption evidence. The runtime is relatively popular among template search results, but its generator has a much smaller count. [Runtime registry page](https://mooncakes.io/docs/justjavac/template@0.1.1), [generator registry page](https://mooncakes.io/docs/justjavac/template_codegen@0.1.3).

The actual downloaded manifests identify both as MIT-licensed. The runtime has no external module dependencies; the generator depends on `moonbitlang/x@0.4.46` and imports its filesystem API. Neither manifest restricts targets. The source repository's current HEAD was `ead34e142ffae32efe27a6e94bd511d2997f9be1`, dated 2026-06-29. Registry index publication dates were June 7 for runtime 0.1.1 and June 29 for generator 0.1.3. [Runtime manifest](https://github.com/justjavac/moonbit-template/blob/ead34e142ffae32efe27a6e94bd511d2997f9be1/template/moon.mod), [generator manifest](https://github.com/justjavac/moonbit-template/blob/ead34e142ffae32efe27a6e94bd511d2997f9be1/template_codegen/moon.mod).

The project separates runtime, parser/AST, generator, and runnable examples. It has tests for escaping, filters, malformed tags, source bindings, source generation, include expansion, and CLI errors. CI runs on Ubuntu using the default target; its latest run succeeded on June 29. This provides useful quality evidence, but is not a three-platform acceptance matrix. [CI definition](https://github.com/justjavac/moonbit-template/blob/ead34e142ffae32efe27a6e94bd511d2997f9be1/.github/workflows/ci.yml), [latest CI run](https://github.com/justjavac/moonbit-template/actions/runs/28357635408).

## Fit for moon-new

This is a **precompiled Sailfish/EJS-style engine**. It generates MoonBit `Render` implementations from templates bound to typed MoonBit structs. Its syntax includes `<%= expression %>` for escaped HTML output, `<%- expression %>` for raw output, MoonBit statements, and static includes. The runtime does not provide a `render(template_text, variables)` interpreter. [Parser](https://github.com/justjavac/moonbit-template/blob/ead34e142ffae32efe27a6e94bd511d2997f9be1/template_codegen/parser/parser.mbt), [generator](https://github.com/justjavac/moonbit-template/blob/ead34e142ffae32efe27a6e94bd511d2997f9be1/template_codegen/codegen.mbt), [runtime interface](https://github.com/justjavac/moonbit-template/blob/ead34e142ffae32efe27a6e94bd511d2997f9be1/template/pkg.generated.mbti).

**Assessment:** it can generate text, but does not naturally fit the agreed phase-one workflow of preserving the official `{{username}}`, `{{module}}`, and `{{package}}` template sources and embedding them with `dev_build` plus `:embed --text`. Embedded source strings alone cannot be rendered by this runtime. Adoption would require converting syntax, creating typed bindings, and adding code generation or an adapter; those are additional design choices. Its documented integration uses a `pre-build` codegen command. It also does not directly solve future rendering of templates downloaded at runtime. [Usage and integration](https://github.com/justjavac/moonbit-template/blob/ead34e142ffae32efe27a6e94bd511d2997f9be1/README.md).

## Local verification

Tests used the downloaded published packages, after inspecting their manifests, code, and test side effects. No codegen executable was globally installed and no moon-new dependency was changed. Test artifacts are under `/tmp/moon-new-precompiled.5AoaGX/`.

Environment: macOS ARM64; `moon 0.1.20260916 (e4f45e4)` and `moonc v0.10.13+75bd53fc8-nightly`.

| Check | Wasm | Native |
| --- | --- | --- |
| Published runtime upstream tests | 7/7 passed | 7/7 passed |
| Published generator, parser, and AST upstream tests | 14/14 passed | 14/14 passed |
| Two consumer probes: braces remain literal; EJS raw expression generates field access | 2/2 passed | 2/2 passed |

The current compiler emitted deprecation warnings, including implicit trait-method promotion and `StringBuilder::new`. No compile or test failures occurred. The consumer probes exercised public generation APIs, not an end-to-end generated application. Windows and Linux execution were not tested locally.

## Recommendation

Keep this candidate in the comparison: its tests, source separation, published runtime dependency footprint, and local results are positive signals. Do not choose it solely from the runtime download count. For moon-new's current source format and embedding decision, prefer evaluating runtime engines that accept the existing braces syntax before proposing a new precompilation workflow.
