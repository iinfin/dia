use anyhow::{Context, Result};
use rusqlite::{Connection, OpenFlags};
use std::path::Path;

use crate::model::Entry;

const CHROMIUM_EPOCH_OFFSET: i64 = 11644473600000000;

pub fn load_history(history_path: &Path, limit: usize) -> Result<Vec<Entry>> {
    let conn = open_immutable(history_path)?;

    let mut stmt = conn
        .prepare(
            "SELECT url, title, visit_count, last_visit_time
             FROM urls
             WHERE hidden = 0
             ORDER BY last_visit_time DESC
             LIMIT ?1",
        )
        .context("failed to prepare history query")?;

    let entries = stmt
        .query_map([limit as i64], |row| {
            let url: String = row.get(0)?;
            let title: String = row.get::<_, Option<String>>(1)?.unwrap_or_default();
            let visit_count: i64 = row.get(2)?;
            let chromium_time: i64 = row.get(3)?;

            let last_visit = chromium_to_unix_ms(chromium_time);

            Ok(Entry::new_history(
                url,
                title,
                visit_count as u32,
                last_visit,
            ))
        })
        .context("failed to execute history query")?
        .filter_map(|r| r.ok())
        .collect();

    Ok(entries)
}

fn open_immutable(path: &Path) -> Result<Connection> {
    let uri = format!("file:{}?immutable=1", path.display());

    Connection::open_with_flags(&uri, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI)
        .with_context(|| format!("failed to open history database at {}", path.display()))
}

fn chromium_to_unix_ms(chromium_time: i64) -> i64 {
    (chromium_time - CHROMIUM_EPOCH_OFFSET) / 1000
}
