# dia-cli

Fast CLI for querying Dia browser history, bookmarks, and tabs.

## Installation

```bash
cargo install --path .
```

## Usage

```bash
# List browsing history
dia-cli history [--limit N] [--profile PROFILE] [--json]

# List bookmarks
dia-cli bookmarks [--profile PROFILE] [--json]

# List open tabs (best-effort)
dia-cli tabs [--profile PROFILE] [--json]

# Search across sources
dia-cli search <QUERY> [--sources history,bookmarks,tabs] [--limit N] [--profile PROFILE] [--json]
```

## Performance

| Command | Target | Actual |
|---------|--------|--------|
| `history --limit 100` | <20ms | ~6ms |
| `bookmarks` | <10ms | ~1.3ms |
| `tabs` | <30ms | ~1.8ms |
| `search` (cold, all sources) | <50ms | ~47ms |

## Raycast Integration

```bash
dia-cli search --json --limit 50 "$RAYCAST_SEARCH_TERM"
```

## Development

```bash
# Build
cargo build

# Release build
cargo build --release

# Run clippy
cargo clippy -- -D warnings
```

## License

GPL-3.0-or-later (due to snss dependency)
