use serde::Serialize;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

#[derive(Debug, Clone, Serialize)]
pub struct Entry {
    pub url: String,
    pub title: String,
    pub source: Source,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub visit_count: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_visit: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub folder: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tab_id: Option<i32>,
    #[serde(skip)]
    pub url_norm: String,
    #[serde(skip)]
    pub title_norm: String,
    #[serde(skip)]
    pub canonical_key: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    History = 0,
    Bookmark = 1,
    Tab = 2,
}

impl Entry {
    pub fn new_history(url: String, title: String, visit_count: u32, last_visit: i64) -> Self {
        let url_norm = normalize(&url);
        let title_norm = normalize(&title);
        let canonical_key = canonical_url_hash(&url);

        Self {
            url,
            title,
            source: Source::History,
            visit_count: Some(visit_count),
            last_visit: Some(last_visit),
            folder: None,
            tab_id: None,
            url_norm,
            title_norm,
            canonical_key,
        }
    }

    pub fn new_bookmark(url: String, title: String, folder: Option<String>) -> Self {
        let url_norm = normalize(&url);
        let title_norm = normalize(&title);
        let canonical_key = canonical_url_hash(&url);

        Self {
            url,
            title,
            source: Source::Bookmark,
            visit_count: None,
            last_visit: None,
            folder,
            tab_id: None,
            url_norm,
            title_norm,
            canonical_key,
        }
    }

    pub fn new_tab(url: String, title: String, tab_id: i32) -> Self {
        let url_norm = normalize(&url);
        let title_norm = normalize(&title);
        let canonical_key = canonical_url_hash(&url);

        Self {
            url,
            title,
            source: Source::Tab,
            visit_count: None,
            last_visit: None,
            folder: None,
            tab_id: Some(tab_id),
            url_norm,
            title_norm,
            canonical_key,
        }
    }
}

pub fn normalize(s: &str) -> String {
    s.to_lowercase()
}

pub fn canonical_url(url: &str) -> &str {
    let s = url
        .trim_start_matches("https://")
        .trim_start_matches("http://")
        .trim_start_matches("www.");

    // Strip fragment and query first, then trailing slash
    let s = s.split('#').next().unwrap_or(s);
    let s = s.split('?').next().unwrap_or(s);
    s.trim_end_matches('/')
}

pub fn canonical_url_hash(url: &str) -> u64 {
    let canonical = canonical_url(url);
    let mut hasher = DefaultHasher::new();
    canonical.hash(&mut hasher);
    hasher.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_lowercases() {
        assert_eq!(normalize("Hello World"), "hello world");
        assert_eq!(normalize("ALLCAPS"), "allcaps");
        assert_eq!(normalize(""), "");
    }

    #[test]
    fn canonical_url_strips_https() {
        assert_eq!(canonical_url("https://example.com"), "example.com");
    }

    #[test]
    fn canonical_url_strips_http() {
        assert_eq!(canonical_url("http://example.com"), "example.com");
    }

    #[test]
    fn canonical_url_strips_www() {
        assert_eq!(canonical_url("www.example.com"), "example.com");
        assert_eq!(canonical_url("https://www.example.com"), "example.com");
    }

    #[test]
    fn canonical_url_strips_trailing_slash() {
        assert_eq!(canonical_url("example.com/"), "example.com");
        assert_eq!(canonical_url("example.com/path/"), "example.com/path");
    }

    #[test]
    fn canonical_url_strips_fragment() {
        assert_eq!(canonical_url("example.com#section"), "example.com");
        assert_eq!(canonical_url("example.com/page#top"), "example.com/page");
    }

    #[test]
    fn canonical_url_strips_query() {
        assert_eq!(canonical_url("example.com?foo=bar"), "example.com");
        assert_eq!(canonical_url("example.com/page?a=1&b=2"), "example.com/page");
    }

    #[test]
    fn canonical_url_combined() {
        assert_eq!(
            canonical_url("https://www.example.com/path/?q=1#sec"),
            "example.com/path"
        );
    }

    #[test]
    fn entry_new_history_sets_fields() {
        let entry = Entry::new_history(
            "https://example.com".to_string(),
            "Example".to_string(),
            5,
            1700000000000,
        );
        assert_eq!(entry.url, "https://example.com");
        assert_eq!(entry.title, "Example");
        assert_eq!(entry.source, Source::History);
        assert_eq!(entry.visit_count, Some(5));
        assert_eq!(entry.last_visit, Some(1700000000000));
        assert!(entry.folder.is_none());
        assert!(entry.tab_id.is_none());
        assert_eq!(entry.title_norm, "example");
    }

    #[test]
    fn entry_new_bookmark_sets_folder() {
        let entry = Entry::new_bookmark(
            "https://example.com".to_string(),
            "Example".to_string(),
            Some("Work / Projects".to_string()),
        );
        assert_eq!(entry.source, Source::Bookmark);
        assert_eq!(entry.folder, Some("Work / Projects".to_string()));
        assert!(entry.visit_count.is_none());
        assert!(entry.tab_id.is_none());
    }

    #[test]
    fn entry_new_tab_sets_tab_id() {
        let entry = Entry::new_tab("https://example.com".to_string(), "Example".to_string(), 42);
        assert_eq!(entry.source, Source::Tab);
        assert_eq!(entry.tab_id, Some(42));
        assert!(entry.visit_count.is_none());
        assert!(entry.folder.is_none());
    }

    #[test]
    fn source_ordering() {
        assert!(Source::Tab > Source::Bookmark);
        assert!(Source::Bookmark > Source::History);
    }
}
