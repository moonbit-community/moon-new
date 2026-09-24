# Precompiled engine assessment

Historical check: **2026-09-18**, macOS ARM64, Moon `e4f45e4`,
moonc `v0.10.13+75bd53fc8-nightly`. Not selected for moon-new.

[justjavac/template 0.1.1](https://mooncakes.io/docs/justjavac/template@0.1.1)
and [template_codegen 0.1.3](https://mooncakes.io/docs/justjavac/template_codegen@0.1.3)
are MIT-licensed. Runtime has no external dependencies; generator uses x 0.4.46.
Inspected [source](https://github.com/justjavac/moonbit-template/tree/ead34e142ffae32efe27a6e94bd511d2997f9be1)
separates runtime, parser/AST, generator, and examples.

This EJS/Sailfish-style pipeline generates typed MoonBit renderers from templates;
it has no runtime interpreter for the original `{{name}}` assets. Adoption would
require syntax conversion, bindings, and code generation beyond `:embed --text`.
It also does not directly handle templates downloaded at runtime.

Published runtime tests (7), generator/parser/AST tests (14), and consumer probes
(2) passed on both native and Wasm, with compiler deprecation warnings. Probes
verified literal braces and generated EJS field access, not an end-to-end generated
application. Linux/Windows were not rerun locally. Runtime popularity alone did
not establish adoption of the generator (58 downloads in the initial snapshot).
