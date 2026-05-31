#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$ROOT_DIR/.zig-cache/spikes"
OUT_WASM="$OUT_DIR/pg_quickjs.wasm"
QJS_DIR="$ROOT_DIR/spikes/wasm/vendor/quickjs"

mkdir -p "$OUT_DIR"

zig cc -target wasm32-wasi -O2 -D_GNU_SOURCE \
  -I "$QJS_DIR" \
  "$ROOT_DIR/spikes/wasm/quickjs_wasm_bridge.c" \
  "$QJS_DIR/quickjs.c" \
  "$QJS_DIR/dtoa.c" \
  "$QJS_DIR/libregexp.c" \
  "$QJS_DIR/libunicode.c" \
  -Wl,--no-entry \
  -Wl,--export=pg_init \
  -Wl,--export=pg_eval_handle \
  -Wl,--export=pg_force_trap \
  -Wl,--export=pg_destroy \
  -o "$OUT_WASM"

printf '%s\n' "$OUT_WASM"
