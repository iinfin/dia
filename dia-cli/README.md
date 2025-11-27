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

# Search across sources
dia-cli search <QUERY> [--sources history,bookmarks] [--limit N] [--profile PROFILE] [--json]
```

## Performance

| Command | Target | Actual |
|---------|--------|--------|
| `history --limit 100` | <20ms | ~6ms |
| `bookmarks` | <10ms | ~1.3ms |
| `search` (cold) | <50ms | ~43ms |

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

MIT
