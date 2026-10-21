name = "moonbit-community/moonrun"

version = "0.1.0"

license = "Apache-2.0"

repository = "https://github.com/moonbit-community/moon-new"

readme = "README.mbt.md"

description = "A MoonBit WebAssembly runner powered by Wasmoon."

preferred_target = "native"

supported_targets = "native"

import {
  "Milky2018/wasmoon@0.17.1",
  "Milky2018/wasm_core@0.17.1",
  "Milky2018/wasmoon_runtime@0.17.1",
  "moonbitlang/async@0.22.4",
  "moonbitlang/x@0.5.5",
  "moonbit-community/moonrun-sqlite3@0.1.0",
  "moonbit-community/toml@0.5.0",
  "moonbit-community/yaml@0.0.8",
}
