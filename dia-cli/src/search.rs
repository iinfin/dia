use ahash::AHashMap;
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};

use crate::model::{Entry, Source};

pub struct SearchEngine {
    matcher: Matcher,
    buf: Vec<char>,
}

impl SearchEngine {
    pub fn new() -> Self {
        Self {
            matcher: Matcher::new(Config::DEFAULT),
            buf: Vec::with_capacity(512),
        }
    }

    pub fn search<'a>(&mut self, entries: &'a [Entry], query: &str, limit: usize) -> Vec<&'a Entry> {
        if query.is_empty() {
            return entries.iter().take(limit).collect();
        }

        let pattern = Pattern::parse(query, CaseMatching::Ignore, Normalization::Smart);

        let mut scored: Vec<(&Entry, f32)> = entries
            .iter()
            .filter_map(|entry| {
                let score = self.score_entry(entry, &pattern)?;
                Some((entry, score))
            })
            .collect();

        if scored.len() > limit {
            scored.select_nth_unstable_by(limit - 1, |a, b| {
                b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal)
            });
            scored.truncate(limit);
        }

        scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

        scored.into_iter().map(|(e, _)| e).collect()
    }

    fn score_entry(&mut self, entry: &Entry, pattern: &Pattern) -> Option<f32> {
        self.buf.clear();
        let title_haystack = Utf32Str::new(&entry.title_norm, &mut self.buf);
        let title_score = pattern.score(title_haystack, &mut self.matcher);

        self.buf.clear();
        let url_haystack = Utf32Str::new(&entry.url_norm, &mut self.buf);
        let url_score = pattern.score(url_haystack, &mut self.matcher);

        let base_score = match (title_score, url_score) {
            (Some(t), Some(u)) => t.max(u) as f32,
            (Some(t), None) => t as f32,
            (None, Some(u)) => u as f32,
            (None, None) => return None,
        };

        let freq_boost = 1.0 + (entry.visit_count.unwrap_or(0) as f32).ln_1p() * 0.1;

        let source_weight = match entry.source {
            Source::Tab => 1.3,
            Source::Bookmark => 1.1,
            Source::History => 1.0,
        };

        Some(base_score * freq_boost * source_weight)
    }
}

pub fn dedupe_entries(entries: Vec<Entry>) -> Vec<Entry> {
    let mut map: AHashMap<u64, Entry> = AHashMap::with_capacity(entries.len());

    for entry in entries {
        map.entry(entry.canonical_key)
            .and_modify(|existing| {
                if entry.source > existing.source && !entry.title.is_empty() {
                    existing.title = entry.title.clone();
                    existing.title_norm = entry.title_norm.clone();
                }
                if let Some(vc) = entry.visit_count {
                    let existing_vc = existing.visit_count.unwrap_or(0);
                    existing.visit_count = Some(existing_vc.saturating_add(vc));
                }
                if existing.last_visit.is_none() {
                    existing.last_visit = entry.last_visit;
                } else if let Some(lv) = entry.last_visit {
                    existing.last_visit = Some(existing.last_visit.unwrap().max(lv));
                }
            })
            .or_insert(entry);
    }

    map.into_values().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_history(url: &str, title: &str, visits: u32, last_visit: i64) -> Entry {
        Entry::new_history(url.to_string(), title.to_string(), visits, last_visit)
    }

    fn make_tab(url: &str, title: &str, tab_id: i32) -> Entry {
        Entry::new_tab(url.to_string(), title.to_string(), tab_id)
    }

    // dedupe_entries tests

    #[test]
    fn dedupe_empty() {
        let result = dedupe_entries(vec![]);
        assert!(result.is_empty());
    }

    #[test]
    fn dedupe_single_entry() {
        let entries = vec![make_history("https://example.com", "Example", 1, 1000)];
        let result = dedupe_entries(entries);
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn dedupe_merges_visit_counts() {
        let entries = vec![
            make_history("https://example.com", "Example", 5, 1000),
            make_history("https://example.com", "Example", 3, 2000),
        ];
        let result = dedupe_entries(entries);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].visit_count, Some(8));
    }

    #[test]
    fn dedupe_prefers_higher_source_title() {
        let entries = vec![
            make_history("https://example.com", "Old Title", 1, 1000),
            make_tab("https://example.com", "Current Tab Title", 1),
        ];
        let result = dedupe_entries(entries);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].title, "Current Tab Title");
    }

    #[test]
    fn dedupe_keeps_max_last_visit() {
        let entries = vec![
            make_history("https://example.com", "Example", 1, 1000),
            make_history("https://example.com", "Example", 1, 2000),
        ];
        let result = dedupe_entries(entries);
        assert_eq!(result[0].last_visit, Some(2000));
    }

    #[test]
    fn dedupe_different_urls_preserved() {
        let entries = vec![
            make_history("https://example.com", "Example", 1, 1000),
            make_history("https://other.com", "Other", 1, 1000),
        ];
        let result = dedupe_entries(entries);
        assert_eq!(result.len(), 2);
    }

    // SearchEngine tests

    #[test]
    fn search_empty_query_returns_first_n() {
        let entries = vec![
            make_history("https://a.com", "A", 1, 1000),
            make_history("https://b.com", "B", 1, 1000),
            make_history("https://c.com", "C", 1, 1000),
        ];
        let mut engine = SearchEngine::new();
        let results = engine.search(&entries, "", 2);
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn search_filters_by_query() {
        let entries = vec![
            make_history("https://rust-lang.org", "Rust Language", 1, 1000),
            make_history("https://python.org", "Python", 1, 1000),
        ];
        let mut engine = SearchEngine::new();
        let results = engine.search(&entries, "rust", 10);
        assert_eq!(results.len(), 1);
        assert!(results[0].url.contains("rust"));
    }

    #[test]
    fn search_respects_limit() {
        let entries: Vec<Entry> = (0..100)
            .map(|i| make_history(&format!("https://example{}.com", i), "Example", 1, 1000))
            .collect();
        let mut engine = SearchEngine::new();
        let results = engine.search(&entries, "example", 5);
        assert_eq!(results.len(), 5);
    }

    #[test]
    fn search_no_match_returns_empty() {
        let entries = vec![make_history("https://example.com", "Example", 1, 1000)];
        let mut engine = SearchEngine::new();
        let results = engine.search(&entries, "nonexistent", 10);
        assert!(results.is_empty());
    }
}
