# Dia CLI — Consolidated Best-of-Breed Plan

## Objective and Constraints

- Deliver a single Rust binary that exposes fast `history`, `bookmarks`, `tabs`, and `search` commands. JSON output is the default for Raycast.
- Responsiveness targets (M-series Mac, ~5k history + ~2k bookmarks + a few hundred tabs):
    - Cold one-shot search (load + query): <50 ms typical; absolute ceiling 150 ms.
    - Fuzzy quality good enough for partial/prefix/typo tolerance; no regex-only fallback.
- Scope boundaries: read-only access; no mutation of Dia data; best-effort tab enumeration via session files; packaged Raycast extension is out of scope.

## Foundations and Rationale

- Language: Rust chosen for predictable cold-start, zero JIT/GC jitter, strong SQLite and binary parsing crates. Node/Bun would require a warmed daemon to compete; Rust meets cold and warm paths without extra infrastructure.
- Binary distribution: static macOS binary (arm64/x64) that Raycast can call directly.
- CLI surface: `dia-cli {history|bookmarks|tabs|search}` with consistent flags: `--profile`, `--limit/--all`, `--sources`, `--json`.
- Fuzzy engine: prefer `nucleo` (fast skim/Smith-Waterman; designed for large lists) if it benchmarks best; fallback to `fuzzy-matcher`/`rapidfuzz` if simpler. Keep matcher reused within a single invocation to avoid setup overhead.
- Output: newline-delimited JSON per item for streaming; optional pretty-print for debugging.

## Key Dependencies (target set)

- `clap` for CLI, `serde`/`serde_json` for models/output.
- `rusqlite` with `bundled` feature for SQLite access; `time` helpers for Chromium timestamp conversion.
- `nucleo` preferred for fuzzy; alternative `fuzzy-matcher` or `rapidfuzz` if simpler.
- `rayon` optional if parsing or matching benefits from parallelism on large datasets.
- `ahash`/`hashbrown` for fast hash maps in dedupe.
- `anyhow` + `thiserror` for ergonomic errors.
- `dirs`/`directories` for HOME resolution if desired (otherwise direct $HOME path join).

## Data Sources and Access Strategy

- Profile root: `~/Library/Application Support/Dia/User Data/<profile>` (default `Default`). Allow `--profile` to switch.
- History:
    - File: `History` (SQLite).
    - Access: `rusqlite` with `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`, using `file:...?...&immutable=1` to avoid locks.
    - Query: `SELECT id, url, title, last_visit_time, visit_count FROM urls ORDER BY last_visit_time DESC LIMIT ?` where limit comes from `--limit` (50/100) or `--all` capped (e.g., 5k–20k).
    - Timestamp: convert Chromium microseconds since Windows epoch to epoch ms on ingest.
    - Safety: if DB is locked, fall back to copying to a temp file only if immutable mode fails (rare).
- Bookmarks:
    - File: `Bookmarks` (Chromium JSON).
    - Access: `serde_json` via BufReader or mmap; traverse `roots.bookmark_bar`, `roots.other`, `roots.synced`.
    - Flatten to list with fields: id, url, title, folder path. Stop at a generous cap (e.g., 20k) to bound worst-case allocations.
- Tabs (Dia lacks AppleScript):
    - Files: newest `Sessions/Tabs_*`; fallback to newest `Sessions/Session_*`.
    - Format: Chromium session-restore “SNSS” command stream (not protobuf; avoid prost schema generation). Steps:
        - Pick candidate by mtime; quick sanity via magic `SNSS` and a handful of URL strings.
        - Parse header/version; iterate commands (per `session_constants.h`):
            - Required handlers: `SetTabWindow`, `SetTabIndexInWindow`, `UpdateTabNavigation`, `SetSelectedNavigationIndex`, `TabClosed` (optional) to keep state consistent.
            - For `UpdateTabNavigation`, read navigation index, URL, title; persist the latest navigation per tab.
        - Assemble `TabItem { window_id, tab_id, index, url, title }`.
        - Cap parsed tabs (e.g., 500) and short-circuit on malformed commands with a warning; return empty on hard failure instead of blocking the CLI.
    - Freshness: choose newest file each run; no caching beyond process lifetime to keep the design simple.
- Freshness tracking:
    - For one-shot invocations, always load; keep caps tight so load is fast. If desired later, mtime-based skips can be added, but current plan assumes clean reload each call.

## Data Model and Normalization

- Common `Entry` (searchable):
    - `url`, `title`, `source` (History|Bookmark|Tab), `visit_count` (history), `last_visit_time` (history), `window_id/tab_id/index` (tabs), `folder` (bookmark).
    - Derived: `norm_url`, `norm_title` (lowercase, Unicode fold), `canonical_url` (strip scheme, trailing slash, fragment; drop `utm_*`, `ref` known trackers).
- Source preference: titles prioritized Tab > Bookmark > History when merging duplicates.
- Caps: preallocate vector with history_len + bookmark_len + tab_len to avoid reallocation churn.

## Dedupe and Merging

- Canonical key: normalized host + path without scheme/trailing slash/fragment; query stripped of tracking params.
- Merge strategy:
    - Aggregate visit_count (sum) and keep max last_visit_time from history.
    - Preserve the richest title (tab > bookmark > history) and keep folder info when present.
    - Track contributing sources to allow source-weighting.

## Search Algorithm and Ranking

- Matcher options: prefer `nucleo` (very fast skim/Smith-Waterman) if it benchmarks best; fallback to `fuzzy-matcher` or `rapidfuzz`. Keep allocation-free hot loop by precomputing normalized fields.
- Scoring:
    - Base fuzzy score = max(titleScore, urlScore).
    - Boosts: prefix match (+large), word-boundary substring (+medium), plain substring (+small).
    - Frequency: multiply by `(1 + log1p(visit_count))`.
    - Source weights: Tab 1.3, Bookmark 1.1, History 1.0 (tunable).
    - Recency tiebreaker: prefer newer `last_visit_time` when scores are close.
- Filtering: drop matches with very low fuzzy score to avoid noise; limit output (default 50).
- Optional cheap prefilter: quick substring check before fuzzy to reduce matcher calls.

## Performance Strategy

- One-shot path only: immutable SQLite read with limit cap; bookmarks parse via BufReader; tabs parse once per invocation. Aim to keep allocations linear and bounded.
- Optional parallelism: rayon for history/bookmarks parse if profiling shows benefit; default to single-thread to reduce contention and startup cost.
- Benchmarks: `hyperfine 'dia-cli search --query foo --json'` (cold). Record target numbers in README.
- Memory: keep under tens of MB by capping items and using compact structs; reuse buffers where practical.

## CLI UX and API Details

- Subcommands and flags:
- `history`: `--limit` (50/100 default 100), `--all` (applies cap), `--profile`, `--json`.
- `bookmarks`: `--profile`, `--json`.
- `tabs`: `--profile`, `--json` (warn to stderr on parse failure, return `[]`).
- `search`: `--sources history,bookmarks,tabs`, `--query`, `--limit` (default 50), `--profile`, `--json`.
- Logging: errors and warnings to stderr; clean JSON to stdout. Non-zero exit codes on fatal errors; tab-parse failures are non-fatal warnings.
- Profiles: default `Default`; allow override; validate path existence with clear errors.

## Implementation Sequence (single-evening, detailed)

1. Scaffold: Cargo project, clap CLI, models, error helpers; ensure `cargo fmt`, `clippy -D warnings` clean.
2. Path resolver: helper to build profile paths (History, Bookmarks, Sessions) with validation and helpful errors.
3. History loader: immutable open, query with limit handling, timestamp conversion, cap enforcement; unit smoke test using a small fixture copy.
4. Bookmarks loader: JSON flatten with folder paths, cap; test with sample JSON.
5. Entry builder + canonicalization + dedupe merge; unit tests for dedupe and canonical URL rules.
6. Fuzzy matcher integration: normalization, prefilter, scoring formula, ranking, limit; tests for scoring/ordering; microbench on synthetic 10k set.
7. Wire `search` command: load sources per flags, build entries, run search, emit JSON.
8. Tabs parser: minimal SNSS decoder with command handlers, cap, warnings; integration test against captured Tabs file if available; fallback-to-empty on hard errors.
9. Validation and perf: `cargo test`, `clippy`, `hyperfine` benchmarks (cold path); manual spot-check of tabs vs Dia UI; README perf notes.

## Suggested File Layout

- `Cargo.toml`, optional `build.rs` (only if needed for generated code; likely not needed since SNSS parsing is manual).
- `src/main.rs` (CLI entry), `src/cli.rs` (arg parsing), `src/config.rs` (paths/constants), `src/history.rs`, `src/bookmarks.rs`, `src/tabs.rs`, `src/search.rs`, `src/model.rs`, `src/output.rs` (JSON helpers).
- `tests/` for integration, `benches/` for microbenchmarks.

## Raycast Integration

- Default call: `dia-cli search --json --sources history,bookmarks,tabs --limit 50 --query "$RAYCAST_SEARCH_TERM"`.
- Result mapping: Raycast displays title + URL; use source indicator (tab/bookmark/history) and frequency/recency as subtleties if desired.

## Risk Mitigation and Fallbacks

- Tab parsing brittleness: keep parser minimal, capped, and fail-open (returns empty with warning).
- Large histories: enforce hard caps; warn when truncation occurs to keep latency bounded.
- Locked History DB: immutable URI first; if fails, optional temp copy; otherwise return error with guidance.
- Fuzzy noise: apply minimum score threshold and prefix/word-boundary boosts to favor high-quality hits.
- Multi-profile: if multiple profiles detected, expose `--profile` and document; default remains `Default`.

## Validation Checklist

- Functional: history/bookmarks commands return JSON; search honors sources, limits, and dedupe; tabs returns best-effort list or empty with warning.
- Performance: measured cold-path latencies within targets; document numbers.
- Quality: no clippy warnings; unit tests for loaders, canonicalization, dedupe, scoring; integration test for search ordering; tab parser tested when sample exists.
- Documentation: README snippet for Raycast usage, perf numbers, known limitations (tab parsing best-effort, caps).

## Build and Distribution

- Dev: `cargo build`.
- Release: `cargo build --release --config 'profile.release.lto = true'` then `strip` (or `cargo install --path .`) to keep the binary small (<5–6 MB). Use `RUSTFLAGS="-C target-cpu=native"` optionally for local speed.
- Install path for Raycast: `~/.cargo/bin/dia-cli` (rename in Raycast script if desired).

## Success Criteria and Checks

- `dia-cli history --limit 100 --json` returns within ~20 ms on typical Dia History DB sizes.
- `dia-cli bookmarks --json` returns within ~10–20 ms for a few thousand bookmarks.
- `dia-cli tabs --json` returns a best-effort list quickly (<20–30 ms) or empty with a warning; never blocks.
- `dia-cli search --sources history,bookmarks,tabs --limit 50 --json "<q>"` returns ranked, deduped results within <50 ms cold on ~5k history + ~2k bookmarks + a few hundred tabs.
- Benchmarks recorded with `hyperfine`; README notes perf numbers and caps.
