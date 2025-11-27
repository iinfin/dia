#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${DIA_PROFILE:-Default}"
QUERY="${DIA_QUERY:-rust}"
LIMIT="${DIA_LIMIT:-50}"

cd "$ROOT_DIR"

echo "Building dia-zig (ReleaseFast)..."
(cd "$ROOT_DIR/dia-zig" && ZIG_GLOBAL_CACHE_DIR=../.zig-cache ZIG_LOCAL_CACHE_DIR=../.zig-cache \
  zig build -Doptimize=ReleaseFast)

echo "Building dia-rs (release)..."
cargo build --release --manifest-path dia-rs/Cargo.toml

ZIG_BIN="$ROOT_DIR/dia-zig/zig-out/bin/dia-zig"
RS_BIN="$ROOT_DIR/dia-rs/target/release/dia-rs"

if ! command -v hyperfine >/dev/null 2>&1; then
  echo "hyperfine not found; please install it to run benchmarks." >&2
  exit 1
fi

echo "Benchmarking search (profile=${PROFILE}, query='${QUERY}', limit=${LIMIT})"
hyperfine --warmup 1 \
  "${ZIG_BIN} search \"${QUERY}\" --profile \"${PROFILE}\" --limit ${LIMIT} --json" \
  "${RS_BIN} search \"${QUERY}\" --profile \"${PROFILE}\" --limit ${LIMIT} --json"
