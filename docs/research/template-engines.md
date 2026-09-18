# Community template engine comparison

Checked on 2026-09-18 for phase-one default project generation. After reviewing
these findings, the user selected `bobzhang/liquid`, expecting an imminent
upstream update. No engine was added to moon-new during planning. The findings
below describe the reviewed versions, not the quality of a future release.

## Registry survey

Live `moon search` queries covered template, mustache, handlebars, jinja,
stencil, and liquid. `moon view --json` verified the leading candidates below.
Downloads are the registry's counter at the time of the survey, not unique
users or evidence of production adoption. This is a scoped search, not a claim
to have exhaustively audited every published engine.

| Module | Version | Downloads | Fit and evidence |
| --- | --- | ---: | --- |
| [justjavac/template](https://mooncakes.io/docs/justjavac/template@0.1.1) | 0.1.1 | 4,228 | Tested precompiled EJS/Sailfish-style runtime; lacks runtime rendering of existing braces templates |
| [Yoorkin/splice](https://mooncakes.io/docs/Yoorkin/splice@0.1.2) | 0.1.2 | 1,274 | Range-based text editing utility, not a placeholder template interpreter |
| [ryota0624/mustache](https://mooncakes.io/docs/ryota0624/mustache@0.0.6) | 0.0.6 | 94 | Existing source fails to compile on the current toolchain |
| [bobzhang/liquid](https://mooncakes.io/docs/bobzhang/liquid@0.1.1) | 0.1.1 | 37 | Runtime braces syntax; source quality review found hardcoded placeholders in advanced tags |
| [ZSeanYves/moonjinja](https://mooncakes.io/docs/ZSeanYves/moonjinja@0.2.1) | 0.2.1 | 33 | Discovered; not independently audited in this round |
| [LL124-Arch/stencil](https://mooncakes.io/docs/LL124-Arch/stencil@0.1.5) | 0.1.5 | 32 | Discovered; not independently audited in this round |
| [Lyllyl789/mustache](https://mooncakes.io/docs/Lyllyl789/mustache@0.1.6) | 0.1.6 | 24 | Best fit among tested runtime candidates; broad passing tests, but low adoption evidence and release-archive hygiene concerns |
| [jshsj124/moontemplate](https://mooncakes.io/docs/jshsj124/moontemplate@0.1.1) | 0.1.1 | 21 | Braces syntax, but a targeted probe loses supplementary-plane Unicode in variable values |

## Assessment

The relatively popular engine, justjavac/template, has positive local test and
source-organization evidence. Its precompiled expression syntax requires
changing the agreed original-template plus `dev_build :embed --text` workflow.
Its separately published generator had only 58 downloads in the first snapshot
(59 on a subsequent query), so the runtime counter alone is especially weak
evidence for adoption of the whole authoring pipeline.
See [the precompiled-engine review](template-precompiled.md).

Among tested runtime engines, Lyllyl789/mustache preserves the required simple
variables, official file contents, newlines, and supplementary Unicode. That
makes it a candidate, not an automatically approved dependency. Its small
download count and unrelated content in the published archive prevent a strong
maturity claim. Other tested engines had compilation or correctness problems.
See [the runtime-engine review](template-runtime.md).

Liquid offers another runtime API, but its hardcoded tag outputs make a broad
quality recommendation inappropriate even if its existing tests pass.
See [the Liquid review](template-liquid.md).

No audited candidate currently combines relatively high downloads, demonstrated
quality, and a direct fit for the agreed workflow. A reasonable phase-one
recommendation remains a small substitution operation limited to the three
known tokens, using core string facilities. The alternative is an explicitly
accepted dependency on the low-download runtime candidate after reviewing its
release caveats. Neither choice settles the format or feature set for future
Git repository templates.

The earlier recommendation above was superseded by the user's explicit
selection of `bobzhang/liquid`. Use Liquid in the implementation plan and
recheck its published version and required behavior before integration.
