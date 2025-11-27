use ahash::RandomState;
use serde::Serialize;
use std::hash::{BuildHasher, Hasher};

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

pub fn canonical_url_hash(url: &str) -> u64 {
    let canonical = url
        .trim_start_matches("https://")
        .trim_start_matches("http://")
        .trim_start_matches("www.")
        .trim_end_matches('/')
        .split('#')
        .next()
        .unwrap_or(url)
        .split('?')
        .next()
        .unwrap_or(url);

    let state = RandomState::new();
    let mut hasher = state.build_hasher();
    hasher.write(canonical.as_bytes());
    hasher.finish()
}
