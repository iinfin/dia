use anyhow::{Context, Result};
use std::collections::HashMap;
use std::fs;
use std::path::Path;

use crate::model::Entry;

const TAB_CAP: usize = 500;

pub fn load_tabs(sessions_dir: &Path) -> Result<Vec<Entry>> {
    let session_file = find_newest_session_file(sessions_dir)?;

    let data = fs::read(&session_file)
        .with_context(|| format!("failed to read {}", session_file.display()))?;

    let snss = match snss::parse(&data) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("warning: failed to parse session file: {:?}", e);
            return Ok(Vec::new());
        }
    };

    // Collect tabs, keeping only highest index (current page) per tab ID
    let mut tab_map: HashMap<i32, (i32, String, String)> = HashMap::new();

    for cmd in snss.commands {
        if let snss::Content::Tab(tab) = cmd.content {
            if tab.url.is_empty() {
                continue;
            }
            tab_map
                .entry(tab.id)
                .and_modify(|(idx, url, title)| {
                    if tab.index > *idx {
                        *idx = tab.index;
                        *url = tab.url.clone();
                        *title = tab.title.clone();
                    }
                })
                .or_insert((tab.index, tab.url, tab.title));
        }
    }

    let entries: Vec<Entry> = tab_map
        .into_iter()
        .take(TAB_CAP)
        .map(|(tab_id, (_, url, title))| Entry::new_tab(url, title, tab_id))
        .collect();

    Ok(entries)
}

fn find_newest_session_file(sessions_dir: &Path) -> Result<std::path::PathBuf> {
    if !sessions_dir.exists() {
        anyhow::bail!("sessions directory not found: {}", sessions_dir.display());
    }

    let mut candidates: Vec<_> = fs::read_dir(sessions_dir)?
        .filter_map(|e| e.ok())
        .filter(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            name.starts_with("Tabs_") || name.starts_with("Session_")
        })
        .collect();

    // Sort: prefer Tabs_* over Session_*, then by mtime descending
    candidates.sort_by(|a, b| {
        let a_is_tabs = a.file_name().to_string_lossy().starts_with("Tabs_");
        let b_is_tabs = b.file_name().to_string_lossy().starts_with("Tabs_");

        match (a_is_tabs, b_is_tabs) {
            (true, false) => std::cmp::Ordering::Less,
            (false, true) => std::cmp::Ordering::Greater,
            _ => {
                let a_mtime = a.metadata().and_then(|m| m.modified()).ok();
                let b_mtime = b.metadata().and_then(|m| m.modified()).ok();
                b_mtime.cmp(&a_mtime)
            }
        }
    });

    candidates
        .first()
        .map(|e| e.path())
        .ok_or_else(|| anyhow::anyhow!("no session files found in {}", sessions_dir.display()))
}
