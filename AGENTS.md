# Dia CLI

Fast read-only CLI for Dia browser history, bookmarks, tabs. Raycast-ready.

## Core Facts

- Single Zig binary, macOS arm64/x64
- Cold-start target: <50ms for combined search
- Profile root: `~/Library/Application Support/Dia/User Data/<profile>`

## 1. Architecture

1. Modules: main.zig (CLI), config.zig (paths), model.zig (Entry), search.zig (fuzzy), history.zig (SQLite), bookmarks.zig (JSON), tabs.zig (SNSS), output.zig
2. Data Flow: load sources -> normalize -> dedupe by canonical URL -> fuzzy rank -> JSON out
3. Deps: system sqlite3, libc

## 2. Commands

1. `dia-cli history [--limit N] [--profile P] [--json]` - browse history (default limit 100)
2. `dia-cli bookmarks [--profile P] [--json]` - all bookmarks
3. `dia-cli tabs [--profile P] [--json]` - open tabs (best-effort, warns on failure)
4. `dia-cli search [QUERY] [--all] [--sources S] [--limit N] [--profile P] [--json]` - fuzzy search across sources

## 3. Data Sources

1. History: `<profile>/History` (SQLite), cap 5000, immutable read
2. Bookmarks: `<profile>/Bookmarks` (JSON), cap 10000
3. Tabs: `<profile>/Sessions/Tabs_*` (SNSS), cap 500, graceful fallback to empty

## 4. Performance Targets

1. history --limit 100: <20ms target, ~6ms actual
2. bookmarks: <10ms target, ~1.3ms actual
3. tabs: <30ms target, ~1.8ms actual
4. search (cold, all): <50ms target, ~47ms actual

## 5. Development

1. Build: `zig build` (dev), `zig build -Doptimize=ReleaseFast` (optimized)
2. Test: `zig build test`
3. Scripts: `b build`, `b test`, `b run` (`b` is an alias for `bun run` in my global shell dotfiles setup)

## 6. Conventions

1. Commits: commitlint `type(scope): message`. Types: feat/fix/docs/style/refactor/test/chore. Scopes: core/data/search/deps/docs/repo.
2. Code Quality: zig fmt clean, unit tests for new modules
3. Error Handling: stderr for warnings, stdout for JSON, graceful fallback (tabs returns [] on failure)
4. No emojis anywhere
