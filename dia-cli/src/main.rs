mod bookmarks;
mod config;
mod history;
mod model;
mod output;
mod search;
mod tabs;

use anyhow::Result;
use clap::{Parser, Subcommand};

use config::Config;
use search::{dedupe_entries, SearchEngine};

#[derive(Parser)]
#[command(name = "dia-cli")]
#[command(about = "Fast CLI for querying Dia browser history, bookmarks, and tabs")]
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

    /// List open tabs (best-effort)
    Tabs {
        /// Browser profile name
        #[arg(short, long, default_value = "Default")]
        profile: String,

        /// Output as JSON array (default: newline-delimited JSON)
        #[arg(long)]
        json: bool,
    },

    /// Search history, bookmarks, and tabs
    Search {
        /// Search query (optional if --all is used)
        query: Option<String>,

        /// Return all entries without filtering
        #[arg(short, long)]
        all: bool,

        /// Sources to search (comma-separated: history,bookmarks,tabs)
        #[arg(short, long, default_value = "history,bookmarks,tabs")]
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
        Commands::History {
            limit,
            profile,
            json,
        } => {
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

        Commands::Tabs { profile, json } => {
            let config = Config::new(&profile)?;
            let entries = tabs::load_tabs(&config.sessions_dir())?;

            if json {
                output::print_entries_array(&entries);
            } else {
                output::print_entries(&entries);
            }
        }

        Commands::Search {
            query,
            all,
            sources,
            limit,
            profile,
            json,
        } => {
            let query = match (&query, all) {
                (Some(q), _) => q.clone(),
                (None, true) => String::new(),
                (None, false) => {
                    eprintln!("error: either <QUERY> or --all is required");
                    std::process::exit(1);
                }
            };

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

            if source_list.contains(&"tabs") {
                match tabs::load_tabs(&config.sessions_dir()) {
                    Ok(tab_entries) => all_entries.extend(tab_entries),
                    Err(e) => eprintln!("warning: {}", e),
                }
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
