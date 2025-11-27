const std = @import("std");
const model = @import("model.zig");

const Entry = model.Entry;
const Source = model.Source;

pub const SearchEngine = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SearchEngine {
        return .{ .allocator = allocator };
    }

    pub fn search(
        self: *SearchEngine,
        entries: []Entry,
        query: []const u8,
        limit: usize,
    ) ![]Entry {
        if (limit == 0) return &[_]Entry{};

        if (query.len == 0) {
            const take = @min(limit, entries.len);
            const out = try self.allocator.alloc(Entry, take);
            @memcpy(out, entries[0..take]);
            return out;
        }

        const query_norm = try model.normalizeAlloc(self.allocator, query);
        defer self.allocator.free(query_norm);

        var scored = std.ArrayList(ScoredEntry){};
        defer scored.deinit(self.allocator);

        for (entries) |entry| {
            if (scoreEntry(entry, query_norm)) |score| {
                try scored.append(self.allocator, .{ .entry = entry, .score = score });
            }
        }

        if (scored.items.len == 0) return &[_]Entry{};

        std.sort.pdq(ScoredEntry, scored.items, {}, descScore);

        if (scored.items.len > limit) {
            scored.shrinkRetainingCapacity(limit);
        }

        const out = try self.allocator.alloc(Entry, scored.items.len);
        for (scored.items, 0..) |s, idx| {
            out[idx] = s.entry;
        }
        return out;
    }
};

const ScoredEntry = struct {
    entry: Entry,
    score: f64,
};

fn descScore(_: void, a: ScoredEntry, b: ScoredEntry) bool {
    return a.score > b.score;
}

fn fuzzyScore(haystack: []const u8, needle: []const u8) ?f64 {
    if (needle.len == 0) return 1.0;
    if (needle.len > haystack.len) return null;

    if (std.mem.indexOf(u8, haystack, needle)) |idx| {
        const proximity: f64 = 1.0 / @as(f64, @floatFromInt(idx + 1));
        const coverage: f64 = @as(f64, @floatFromInt(needle.len)) /
            @as(f64, @floatFromInt(haystack.len));
        return 1.0 + proximity + coverage;
    }

    var nidx: usize = 0;
    for (haystack) |c| {
        if (c == needle[nidx]) {
            nidx += 1;
            if (nidx == needle.len) return 0.5;
        }
    }
    return null;
}

fn scoreEntry(entry: Entry, query_norm: []const u8) ?f64 {
    const title_score = fuzzyScore(entry.title_norm, query_norm);
    const url_score = fuzzyScore(entry.url_norm, query_norm);

    const base = if (title_score) |ts| blk: {
        if (url_score) |us| {
            break :blk if (ts > us) ts else us;
        }
        break :blk ts;
    } else url_score orelse return null;

    const freq = entry.visit_count orelse 0;
    const freq_boost = 1.0 + std.math.log1p(@as(f64, @floatFromInt(freq))) * 0.1;
    const weighted = base * freq_boost * entry.source.weight();
    return weighted;
}

pub fn dedupeEntries(allocator: std.mem.Allocator, entries: []Entry) ![]Entry {
    var map = std.AutoHashMap(u64, usize).init(allocator);
    defer map.deinit();

    var out = std.ArrayList(Entry){};
    errdefer out.deinit(allocator);

    for (entries) |entry| {
        if (map.get(entry.canonical_key)) |idx| {
            var existing = &out.items[idx];
            if (@intFromEnum(entry.source) > @intFromEnum(existing.source) and entry.title.len > 0) {
                existing.title = entry.title;
                existing.title_norm = entry.title_norm;
                existing.source = entry.source;
            }

            if (entry.visit_count) |vc| {
                const existing_vc = existing.visit_count orelse 0;
                const sum = std.math.add(u32, existing_vc, vc) catch std.math.maxInt(u32);
                existing.visit_count = sum;
            }

            if (existing.last_visit == null) {
                existing.last_visit = entry.last_visit;
            } else if (entry.last_visit) |lv| {
                if (existing.last_visit.? < lv) existing.last_visit = lv;
            }
        } else {
            try map.put(entry.canonical_key, out.items.len);
            try out.append(allocator, entry);
        }
    }

    return out.toOwnedSlice(allocator);
}

// tests
test "dedupe merges visit counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var entries = [_]Entry{
        try Entry.initHistory(alloc, "https://example.com", "Example", 5, 1000),
        try Entry.initHistory(alloc, "https://example.com", "Example", 3, 2000),
    };
    const result = try dedupeEntries(alloc, &entries);
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u32, 8), result[0].visit_count.?);
}

test "dedupe prefers newer source title" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var entries = [_]Entry{
        try Entry.initHistory(alloc, "https://example.com", "Old Title", 1, 1000),
        try Entry.initTab(alloc, "https://example.com", "Current Tab Title", 1),
    };

    const result = try dedupeEntries(alloc, &entries);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("Current Tab Title", result[0].title);
    try std.testing.expectEqual(Source.tab, result[0].source);
}

test "dedupe keeps max last visit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var entries = [_]Entry{
        try Entry.initHistory(alloc, "https://example.com", "Example", 1, 1000),
        try Entry.initHistory(alloc, "https://example.com", "Example", 1, 2000),
    };

    const result = try dedupeEntries(alloc, &entries);
    defer alloc.free(result);
    try std.testing.expectEqual(@as(i64, 2000), result[0].last_visit.?);
}

test "search filters by query and respects limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var entries = [_]Entry{
        try Entry.initHistory(alloc, "https://rust-lang.org", "Rust Language", 1, 1000),
        try Entry.initHistory(alloc, "https://python.org", "Python", 1, 1000),
        try Entry.initHistory(alloc, "https://rust-book.org", "Rust Book", 1, 1000),
    };

    var engine = SearchEngine.init(alloc);
    const results = try engine.search(&entries, "rust", 2);
    defer alloc.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
    for (results) |r| {
        try std.testing.expect(std.mem.containsAtLeast(u8, r.url, 1, "rust"));
    }
}

test "search no match returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var entries = [_]Entry{try Entry.initHistory(alloc, "https://example.com", "Example", 1, 1000)};
    var engine = SearchEngine.init(alloc);
    const results = try engine.search(&entries, "nonexistent", 10);
    defer alloc.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}
