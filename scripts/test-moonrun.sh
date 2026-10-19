#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
moon build moonrun --target native --release
moon build moonrun/acceptance --target native --release
runner="$PWD/_build/native/release/build/moonbit-community/moonrun/moonrun.exe"
fixtures="$PWD/moonrun/fixtures"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
selection='{"package":"moonrun-fixtures/plain","file_and_index":[["main.mbt",[{"start":0,"end":3}]]]}'
status=0
MOONRUN_INHERITED_POLICY=unsupported "$runner" --version > "$scratch/actual" 2> "$scratch/error" || status=$?
test "$status" -eq 2
status=0
"$runner" > "$scratch/actual" 2> "$scratch/error" || status=$?
test "$status" -eq 2
status=0
"$runner" --policy deny.json ignored.wasm > "$scratch/actual" 2> "$scratch/error" || status=$?
test "$status" -eq 1
targets=("$@")
if [ "${#targets[@]}" -eq 0 ]; then
  targets=(wasm wasm-gc)
fi

for target in "${targets[@]}"; do
  case "$target" in
    wasm|wasm-gc) ;;
    *) printf 'Unsupported fixture target: %s\n' "$target" >&2; exit 2 ;;
  esac
  MOON_WORK=off moon -C "$fixtures" build --target "$target" --debug
  MOON_WORK=off moon -C "$fixtures" test --build-only --target "$target" --debug
  program="$fixtures/_build/$target/debug/build/plain/plain.wasm"
  status=0
  moonrun "$program" -- --flag '中文' > "$scratch/expected" || status=$?
  test "$status" -eq 17
  status=0
  "$runner" "$program" -- --flag '中文' > "$scratch/actual" || status=$?
  test "$status" -eq 17
  cmp "$scratch/expected" "$scratch/actual"

  program="$fixtures/_build/$target/debug/build/files_core/files_core.wasm"
  mkdir "$scratch/files"
  moonrun "$program" "$scratch/files" > "$scratch/expected"
  "$runner" "$program" "$scratch/files" > "$scratch/actual"
  cmp "$scratch/expected" "$scratch/actual"
  rmdir "$scratch/files"

  # The published async library supports the linear-memory Wasm backend.
  if [ "$target" = wasm ]; then
    program="$fixtures/_build/$target/debug/build/async_timers/async_timers.wasm"
    moonrun "$program" > "$scratch/expected"
    "$runner" "$program" > "$scratch/actual"
    cmp "$scratch/expected" "$scratch/actual"

    program="$fixtures/_build/$target/debug/build/async_fs/async_fs.wasm"
    mkdir "$scratch/async-files"
    moonrun "$program" "$scratch/async-files" > "$scratch/expected"
    "$runner" "$program" "$scratch/async-files" > "$scratch/actual"
    cmp "$scratch/expected" "$scratch/actual"
    rmdir "$scratch/async-files"

    program="$fixtures/_build/$target/debug/build/async_process/async_process.wasm"
    moonrun "$program" > "$scratch/expected" 2> "$scratch/expected-errors"
    "$runner" "$program" > "$scratch/actual" 2> "$scratch/actual-errors"
    cmp "$scratch/expected" "$scratch/actual"
    cmp "$scratch/expected-errors" "$scratch/actual-errors"
    "$PWD/_build/native/release/build/moonbit-community/moonrun/acceptance/acceptance.exe" "$program" process
    program="$fixtures/_build/$target/debug/build/async_process_failure/async_process_failure.wasm"
    "$PWD/_build/native/release/build/moonbit-community/moonrun/acceptance/acceptance.exe" "$program" process-failure
    program="$fixtures/_build/$target/debug/build/async_process_exit/async_process_exit.wasm"
    "$PWD/_build/native/release/build/moonbit-community/moonrun/acceptance/acceptance.exe" "$program" process-exit
    program="$fixtures/_build/$target/debug/build/async_process_output/async_process_output.wasm"
    "$PWD/_build/native/release/build/moonbit-community/moonrun/acceptance/acceptance.exe" "$program" process-output
    program="$fixtures/_build/$target/debug/build/async_policy/async_policy.wasm"
    cp "$runner" "$scratch/moonx.exe"
    printf '%s\n' '{"env":{"from_host":["*"]},"process":{"spawn":true}}' > "$scratch/parent-policy.json"
    printf '%s\n' '[env]' 'from_host = ["*"]' '[process]' 'spawn = true' > "$scratch/parent-policy.toml"
    printf '%s\n' '// policy:' '//   env:' '//     from_host: ["*"]' '//   process:' '//     spawn: true' '///|' 'fn main {}' > "$scratch/parent-policy.mbtx"
    printf '%s\n' '{"fs":{"read":["*"],"write":["*"]},"process":{"spawn":true}}' > "$scratch/child-policy.json"
    for parent in "$runner" moonrun; do
      for format in json toml mbtx; do
        "$parent" --policy "$scratch/parent-policy.$format" "$program" "$scratch/moonx.exe" "$program" "$scratch/child-policy.json" "$scratch/forbidden"
      done
    done
    test ! -e "$scratch/forbidden"
    program="$fixtures/_build/$target/debug/build/async_orphan/async_orphan.wasm"
    "$PWD/_build/native/release/build/moonbit-community/moonrun/acceptance/acceptance.exe" "$program" orphan

    program="$fixtures/_build/$target/debug/build/async_watch/async_watch.wasm"
    moonrun "$program" > "$scratch/expected"
    "$runner" "$program" > "$scratch/actual"
    cmp "$scratch/expected" "$scratch/actual"

    program="$fixtures/_build/$target/debug/build/async_stdio/async_stdio.wasm"
    "$PWD/_build/native/release/build/moonbit-community/moonrun/acceptance/acceptance.exe" "$program"

    program="$fixtures/_build/$target/debug/build/async_net/async_net.wasm"
    moonrun "$program" > "$scratch/expected"
    "$runner" "$program" > "$scratch/actual"
    cmp "$scratch/expected" "$scratch/actual"
    "$PWD/_build/native/release/build/moonbit-community/moonrun/acceptance/acceptance.exe" "$program" network
    program="$fixtures/_build/$target/debug/build/async_net_cancel/async_net_cancel.wasm"
    "$PWD/_build/native/release/build/moonbit-community/moonrun/acceptance/acceptance.exe" "$program" cancel
  fi

  program="$fixtures/_build/$target/debug/test/plain/plain.internal_test.wasm"
  moonrun --test-args "$selection" "$program" > "$scratch/expected"
  "$runner" --test-args "$selection" "$program" > "$scratch/actual"
  cmp "$scratch/expected" "$scratch/actual"
done
printf 'moonrun acceptance passed for: %s\n' "${targets[*]}"
