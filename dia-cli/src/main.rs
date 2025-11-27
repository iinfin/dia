mod bookmarks;
mod config;
mod history;
mod model;
mod output;
mod search;

use anyhow::Result;
use clap::{Parser, Subcommand};

use config::Config;
use search::{dedupe_entries, SearchEngine};

#[derive(Parser)]
#[command(name = "dia-cli")]
#[command(about = "Fast CLI for querying Dia browser history and bookmarks")]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// List browsing history
    History {
        /// Maximum number of entries to return
        #[arg(short, long, default_value = "100")]
        limit: usize,

        /// Browser profile name
        #[arg(short, long, default_value = "Default")]
        profile: String,

        /// Output as JSON array (default: newline-delimited JSON)
        #[arg(long)]
        json: bool,
    },

    /// List bookmarks
    Bookmarks {
        /// Browser profile name
        #[arg(short, long, default_value = "Default")]
        profile: String,

        /// Output as JSON array (default: newline-delimited JSON)
        #[arg(long)]
        json: bool,
    },

    /// Search history and bookmarks
    Search {
        /// Search query
        query: String,

        /// Sources to search (comma-separated: history,bookmarks)
        #[arg(short, long, default_value = "history,bookmarks")]
        sources: String,

        /// Maximum number of results
        #[arg(short, long, default_value = "50")]
        limit: usize,

        /// Browser profile name
        #[arg(short, long, default_value = "Default")]
        profile: String,

        /// Output as JSON array (default: search result object)
        #[arg(long)]
        json: bool,
    },
}

fn main() {
    if let Err(e) = run() {
        eprintln!("error: {:#}", e);
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::History { limit, profile, json } => {
            let config = Config::new(&profile)?;
            let entries = history::load_history(&config.history_path(), limit)?;

            if json {
                output::print_entries_array(&entries);
            } else {
                output::print_entries(&entries);
            }
        }

        Commands::Bookmarks { profile, json } => {
            let config = Config::new(&profile)?;
            let entries = bookmarks::load_bookmarks(&config.bookmarks_path())?;

            if json {
                output::print_entries_array(&entries);
            } else {
                output::print_entries(&entries);
            }
        }

        Commands::Search {
            query,
            sources,
            limit,
            profile,
            json,
        } => {
            let config = Config::new(&profile)?;
            let source_list: Vec<&str> = sources.split(',').map(|s| s.trim()).collect();

            let mut all_entries = Vec::new();

            if source_list.contains(&"history") {
                let history_entries = history::load_history(&config.history_path(), 5000)?;
                all_entries.extend(history_entries);
            }

            if source_list.contains(&"bookmarks") {
                let bookmark_entries = bookmarks::load_bookmarks(&config.bookmarks_path())?;
                all_entries.extend(bookmark_entries);
            }

            let deduped = dedupe_entries(all_entries);

            let mut engine = SearchEngine::new();
            let results = engine.search(&deduped, &query, limit);

            let owned_results: Vec<_> = results.into_iter().cloned().collect();

            if json {
                output::print_entries_array(&owned_results);
            } else {
                output::print_search_results(&owned_results);
            }
        }
    }

    Ok(())
}
