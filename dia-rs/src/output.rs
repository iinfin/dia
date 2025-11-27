use serde::Serialize;

use crate::model::Entry;

pub fn print_entries(entries: &[Entry]) {
    for entry in entries {
        if let Ok(json) = serde_json::to_string(entry) {
            println!("{}", json);
        }
    }
}

pub fn print_entries_array(entries: &[Entry]) {
    if let Ok(json) = serde_json::to_string(entries) {
        println!("{}", json);
    }
}

#[derive(Serialize)]
pub struct SearchResult<'a> {
    pub results: &'a [Entry],
    pub count: usize,
}

impl<'a> SearchResult<'a> {
    pub fn new(results: &'a [Entry]) -> Self {
        Self {
            results,
            count: results.len(),
        }
    }
}

pub fn print_search_results(entries: &[Entry]) {
    let result = SearchResult::new(entries);
    if let Ok(json) = serde_json::to_string(&result) {
        println!("{}", json);
    }
}
