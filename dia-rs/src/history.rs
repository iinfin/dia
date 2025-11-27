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

    Connection::open_with_flags(
        &uri,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )
    .with_context(|| format!("failed to open history database at {}", path.display()))
}

pub(crate) fn chromium_to_unix_ms(chromium_time: i64) -> i64 {
    (chromium_time - CHROMIUM_EPOCH_OFFSET) / 1000
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use tempfile::NamedTempFile;

    fn create_test_db() -> NamedTempFile {
        let f = NamedTempFile::new().unwrap();
        let conn = Connection::open(f.path()).unwrap();
        conn.execute(
            "CREATE TABLE urls (
                url TEXT NOT NULL,
                title TEXT,
                visit_count INTEGER DEFAULT 0,
                last_visit_time INTEGER DEFAULT 0,
                hidden INTEGER DEFAULT 0
            )",
            [],
        )
        .unwrap();
        f
    }

    fn insert_entry(path: &Path, url: &str, title: &str, visits: i64, time: i64, hidden: bool) {
        let conn = Connection::open(path).unwrap();
        conn.execute(
            "INSERT INTO urls (url, title, visit_count, last_visit_time, hidden) VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![url, title, visits, time, if hidden { 1 } else { 0 }],
        )
        .unwrap();
    }

    #[test]
    fn chromium_epoch_conversion() {
        // 2023-11-15 00:00:00 UTC in Chromium time
        // Unix: 1700006400 seconds = 1700006400000 ms
        // Chromium: (1700006400 * 1000000) + 11644473600000000 = 13344480000000000
        let chromium = 13344480000000000_i64;
        let unix_ms = chromium_to_unix_ms(chromium);
        assert_eq!(unix_ms, 1700006400000);
    }

    #[test]
    fn load_history_basic() {
        let f = create_test_db();
        insert_entry(
            f.path(),
            "https://example.com",
            "Example",
            5,
            13344480000000000,
            false,
        );

        let entries = load_history(f.path(), 10).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].url, "https://example.com");
        assert_eq!(entries[0].title, "Example");
        assert_eq!(entries[0].visit_count, Some(5));
    }

    #[test]
    fn load_history_respects_limit() {
        let f = create_test_db();
        for i in 0..10 {
            insert_entry(
                f.path(),
                &format!("https://example{}.com", i),
                "Example",
                1,
                13344480000000000 + i,
                false,
            );
        }

        let entries = load_history(f.path(), 5).unwrap();
        assert_eq!(entries.len(), 5);
    }

    #[test]
    fn load_history_filters_hidden() {
        let f = create_test_db();
        insert_entry(f.path(), "https://visible.com", "Visible", 1, 1000, false);
        insert_entry(f.path(), "https://hidden.com", "Hidden", 1, 2000, true);

        let entries = load_history(f.path(), 10).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].url, "https://visible.com");
    }

    #[test]
    fn load_history_orders_by_last_visit_desc() {
        let f = create_test_db();
        insert_entry(f.path(), "https://old.com", "Old", 1, 1000, false);
        insert_entry(f.path(), "https://new.com", "New", 1, 2000, false);

        let entries = load_history(f.path(), 10).unwrap();
        assert_eq!(entries[0].url, "https://new.com");
        assert_eq!(entries[1].url, "https://old.com");
    }

    #[test]
    fn load_history_handles_null_title() {
        let f = create_test_db();
        let conn = Connection::open(f.path()).unwrap();
        conn.execute(
            "INSERT INTO urls (url, title, visit_count, last_visit_time, hidden) VALUES (?1, NULL, ?2, ?3, ?4)",
            rusqlite::params!["https://example.com", 1, 1000, 0],
        )
        .unwrap();

        let entries = load_history(f.path(), 10).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].title, "");
    }

    #[test]
    fn load_history_empty_db() {
        let f = create_test_db();
        let entries = load_history(f.path(), 10).unwrap();
        assert!(entries.is_empty());
    }
}
