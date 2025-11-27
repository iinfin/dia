use anyhow::{Context, Result};
use serde::Deserialize;
use std::fs::File;
use std::io::BufReader;
use std::path::Path;

use crate::model::Entry;

#[derive(Deserialize)]
struct BookmarkFile {
    roots: BookmarkRoots,
}

#[derive(Deserialize)]
struct BookmarkRoots {
    bookmark_bar: Option<BookmarkNode>,
    other: Option<BookmarkNode>,
    synced: Option<BookmarkNode>,
}

#[derive(Deserialize)]
struct BookmarkNode {
    name: Option<String>,
    #[serde(rename = "type")]
    node_type: Option<String>,
    url: Option<String>,
    children: Option<Vec<BookmarkNode>>,
}

const MAX_BOOKMARKS: usize = 10000;

pub fn load_bookmarks(bookmarks_path: &Path) -> Result<Vec<Entry>> {
    if !bookmarks_path.exists() {
        return Ok(Vec::new());
    }

    let file = File::open(bookmarks_path)
        .with_context(|| format!("failed to open bookmarks at {}", bookmarks_path.display()))?;

    let reader = BufReader::with_capacity(16 * 1024, file);
    let bookmark_file: BookmarkFile = serde_json::from_reader(reader)
        .with_context(|| format!("failed to parse bookmarks JSON at {}", bookmarks_path.display()))?;

    let mut entries = Vec::with_capacity(500);

    if let Some(ref node) = bookmark_file.roots.bookmark_bar {
        flatten_node(node, String::new(), &mut entries);
    }
    if let Some(ref node) = bookmark_file.roots.other {
        flatten_node(node, String::new(), &mut entries);
    }
    if let Some(ref node) = bookmark_file.roots.synced {
        flatten_node(node, String::new(), &mut entries);
    }

    Ok(entries)
}

fn flatten_node(node: &BookmarkNode, folder_path: String, entries: &mut Vec<Entry>) {
    if entries.len() >= MAX_BOOKMARKS {
        return;
    }

    let node_type = node.node_type.as_deref().unwrap_or("unknown");

    match node_type {
        "url" => {
            if let (Some(url), Some(title)) = (&node.url, &node.name) {
                let folder = if folder_path.is_empty() {
                    None
                } else {
                    Some(folder_path)
                };
                entries.push(Entry::new_bookmark(url.clone(), title.clone(), folder));
            }
        }
        "folder" => {
            let new_path = match (&folder_path, &node.name) {
                (p, Some(n)) if p.is_empty() => n.clone(),
                (p, Some(n)) => format!("{} / {}", p, n),
                (p, None) => p.clone(),
            };

            if let Some(children) = &node.children {
                for child in children {
                    flatten_node(child, new_path.clone(), entries);
                }
            }
        }
        _ => {}
    }
}
