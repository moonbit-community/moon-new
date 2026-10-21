# moonrun

A native MoonBit WebAssembly runner using Wasmoon's JIT compiler. This module is under development and does not yet replace the official moonrun.

Run it from the workspace root:

```sh
moon run moonrun -- program.wasm -- argument
moon run moonrun -- --test-args '<test selection JSON>' tests.wasm
```

The root package is the CLI. The `moonbit-community/moonrun/runtime` package provides `Module::from_bytes`, `Module::load_file`, and synchronous `Module::run`. Each run has fresh guest state, arguments, environment, working directory, and optional standard-stream callbacks. Guest termination returns `Completed`, `Exited(code)`, `Signaled(signal)`, or `Trapped(message)` without exiting the embedding process. Invalid input and setup failures raise errors. Execution blocks the calling thread and does not require an async event loop. Native workers own blocking jobs; guest async scheduling remains inside the Wasm module. An optional `RunControl`, with a polling callback, forwards signals to one guest without installing process-wide signal handlers. The CLI relays operating-system signals and restores its handlers on exit.

Implemented interfaces include character output, core environment and filesystem imports, JS strings, `ffi-bytes`, SQLite, Wasm exceptions, WASI Preview 1, the MoonBit test-driver protocol, and MoonBit async timers, worker jobs, file I/O, directory operations and watchers, TCP/UDP sockets, DNS, process spawning and waiting, pipes, readiness events, and Windows completion records. Guest event-bus waits use independent native storage and cancellable waits. Pending jobs retain their resources until completion or cancellation acknowledgement; host reference values are retained until the run ends.

Policies can be supplied through `--policy <PATH>` or `Policy::load_file`. A `.mbtx` file uses YAML from its leading `// policy:` comment block. Other files use JSON when their extension is `.json` or their first non-whitespace character is `{`, and TOML otherwise. `Policy::from_json` also accepts JSON directly. All formats share the same schema and deny core/async filesystem, network, environment, and process access by default. Filesystem roots are resolved relative to the policy file, or to `--policy-source-dir` when supplied. Direct child `moonx` invocations receive an inherited policy which takes precedence over their command-line policy. As in the Rust runner, **WASI is not covered by these policies**. Allowing a process to spawn grants that process the host user's ambient access; it is not an operating-system sandbox. SQLite file access follows the filesystem policy. As in the Rust runner, SQL authorization rejects ATTACH, DETACH, and PRAGMA statements other than encoding.

TLS remains deferred until async exposes an independent TLS session API ([upstream issue](https://github.com/moonbitlang/async/issues/668)). Unsupported imports fail explicitly. Use `--stack-size <KiB>` to configure the native guest stack (16 MiB by default), and `--no-stack-trace` to omit guest frames from trap messages.

The acceptance script builds unmodified MoonBit fixtures and compares output and exit status with the installed official runner:

```sh
bash scripts/test-moonrun.sh
```
