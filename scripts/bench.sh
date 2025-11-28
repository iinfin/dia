#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${DIA_PROFILE:-Default}"
QUERY_LIST="${DIA_QUERIES:-}"
if [[ -z "${QUERY_LIST}" && -n "${DIA_QUERY:-}" ]]; then
  QUERY_LIST="${DIA_QUERY}"
fi
if [[ -z "${QUERY_LIST}" ]]; then
  QUERY_LIST="rust,zig,chrome,github,frame.io,youtube.com,https://news.ycombinator.com/,ai,linkedin"
fi
LIMIT="${DIA_LIMIT:-500}"
WARMUP="${DIA_WARMUP:-3}"
IFS=',' read -r -a QUERY_ARRAY <<< "${QUERY_LIST}"
QUERY_COUNT="${#QUERY_ARRAY[@]}"

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

echo "Benchmarking search (profile=${PROFILE}, queries=${QUERY_COUNT} values, limit=${LIMIT}, warmup=${WARMUP}, min-runs=100; random query per run)"

RANDOM_QUERY_SNIPPET='IFS=, read -r -a qs <<< "$DIA_QUERY_LIST"; query=${qs[RANDOM % ${#qs[@]}]}; exec "$1" search "$query" --profile "$DIA_PROFILE" --limit "$DIA_LIMIT" --json'

hyperfine --warmup "${WARMUP}" --min-runs 100 \
  "DIA_QUERY_LIST='${QUERY_LIST}' DIA_PROFILE='${PROFILE}' DIA_LIMIT='${LIMIT}' bash -c '${RANDOM_QUERY_SNIPPET}' _ '${ZIG_BIN}'" \
  "DIA_QUERY_LIST='${QUERY_LIST}' DIA_PROFILE='${PROFILE}' DIA_LIMIT='${LIMIT}' bash -c '${RANDOM_QUERY_SNIPPET}' _ '${RS_BIN}'"
