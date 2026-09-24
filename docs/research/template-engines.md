# Template-engine decision

Historical survey: **2026-09-18**. The user selected `bobzhang/liquid` after
reviewing these findings. Earlier substitution-only and Mustache recommendations
are superseded. Counts are registry snapshots, not unique users or proof of adoption;
findings apply to the listed versions, not later releases.

| Module | Version | Downloads | Finding |
| --- | --- | ---: | --- |
| [justjavac/template](https://mooncakes.io/docs/justjavac/template@0.1.1) | 0.1.1 | 4,228 | Precompiled EJS/Sailfish; requires a different authoring pipeline |
| [Yoorkin/splice](https://mooncakes.io/docs/Yoorkin/splice@0.1.2) | 0.1.2 | 1,274 | Range replacement, not a template interpreter |
| [ryota0624/mustache](https://mooncakes.io/docs/ryota0624/mustache@0.0.6) | 0.0.6 | 94 | Did not compile on the inspected toolchain |
| [bobzhang/liquid](https://mooncakes.io/docs/bobzhang/liquid@0.1.1) | 0.1.1 | 37 | Selected; required substitutions pass, advanced tags have placeholders |
| [ZSeanYves/moonjinja](https://mooncakes.io/docs/ZSeanYves/moonjinja@0.2.1) | 0.2.1 | 33 | Discovered, not independently audited |
| [LL124-Arch/stencil](https://mooncakes.io/docs/LL124-Arch/stencil@0.1.5) | 0.1.5 | 32 | Discovered, not independently audited |
| [Lyllyl789/mustache](https://mooncakes.io/docs/Lyllyl789/mustache@0.1.6) | 0.1.6 | 24 | Compatibility probes pass; archive contains unrelated material |
| [jshsj124/moontemplate](https://mooncakes.io/docs/jshsj124/moontemplate@0.1.1) | 0.1.1 | 21 | Supplementary Unicode interpolation probe fails |

No reviewed candidate combined high downloads, demonstrated quality, and an
unchanged fit for the selected asset workflow. Liquid's expected upstream update
was not evidence of a fix. Its phase-one selection covers the fixed snapshot,
not general conformance or the future Git-template format.
Details: [Liquid](template-liquid.md), [precompiled engine](template-precompiled.md),
[runtime alternatives](template-runtime.md).
