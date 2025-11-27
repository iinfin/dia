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
