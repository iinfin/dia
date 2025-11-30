const std = @import("std");

pub const Source = enum(u8) {
    history = 0,
    bookmark = 1,
    tab = 2,

    pub fn weight(self: Source) f64 {
        return switch (self) {
            .history => 1.0,
            .bookmark => 1.1,
            .tab => 1.3,
        };
    }

    pub fn jsonStringify(self: Source, jw: anytype) !void {
        const label = switch (self) {
            .history => "history",
            .bookmark => "bookmark",
            .tab => "tab",
        };
        try jw.write(label);
    }
};

pub const Entry = struct {
    url: []const u8,
    title: []const u8,
    source: Source,
    visit_count: ?u32,
    last_visit: ?i64,
    folder: ?[]const u8,
    tab_id: ?i32,
    url_norm: []const u8,
    title_norm: []const u8,
    canonical_key: u64,

    pub fn initHistory(
        allocator: std.mem.Allocator,
        url: []const u8,
        title: []const u8,
        visit_count: u32,
        last_visit: i64,
    ) !Entry {
        return try initInternal(
            allocator,
            url,
            title,
            Source.history,
            visit_count,
            last_visit,
            null,
            null,
        );
    }

    pub fn initBookmark(
        allocator: std.mem.Allocator,
        url: []const u8,
        title: []const u8,
        folder: ?[]const u8,
    ) !Entry {
        return try initInternal(
            allocator,
            url,
            title,
            Source.bookmark,
            null,
            null,
            folder,
            null,
        );
    }

    pub fn initTab(
        allocator: std.mem.Allocator,
        url: []const u8,
        title: []const u8,
        tab_id: i32,
    ) !Entry {
        return try initInternal(
            allocator,
            url,
            title,
            Source.tab,
            null,
            null,
            null,
            tab_id,
        );
    }

    fn initInternal(
        allocator: std.mem.Allocator,
        url: []const u8,
        title: []const u8,
        source: Source,
        visit_count: ?u32,
        last_visit: ?i64,
        folder: ?[]const u8,
        tab_id: ?i32,
    ) !Entry {
        const url_copy = try allocator.dupe(u8, url);
        const title_copy = try allocator.dupe(u8, title);
        const url_norm = try normalizeAlloc(allocator, url_copy);
        const title_norm = try normalizeAlloc(allocator, title_copy);
        const canonical_key = canonicalUrlHash(url_copy);
        const folder_copy = if (folder) |f| try allocator.dupe(u8, f) else null;

        return Entry{
            .url = url_copy,
            .title = title_copy,
            .source = source,
            .visit_count = visit_count,
            .last_visit = last_visit,
            .folder = folder_copy,
            .tab_id = tab_id,
            .url_norm = url_norm,
            .title_norm = title_norm,
            .canonical_key = canonical_key,
        };
    }

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.title);
        allocator.free(self.url_norm);
        allocator.free(self.title_norm);
        if (self.folder) |f| allocator.free(f);
        self.* = undefined;
    }

    pub fn jsonStringify(self: Entry, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("url");
        try jw.write(self.url);
        try jw.objectField("title");
        try jw.write(self.title);
        try jw.objectField("source");
        try jw.write(self.source);

        if (self.visit_count) |vc| {
            try jw.objectField("visit_count");
            try jw.write(vc);
        }
        if (self.last_visit) |lv| {
            try jw.objectField("last_visit");
            try jw.write(lv);
        }
        if (self.folder) |f| {
            try jw.objectField("folder");
            try jw.write(f);
        }
        if (self.tab_id) |id| {
            try jw.objectField("tab_id");
            try jw.write(id);
        }

        try jw.endObject();
    }
};

pub fn normalizeAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const buf = try allocator.dupe(u8, s);
    for (buf) |*b| {
        b.* = std.ascii.toLower(b.*);
    }
    return buf;
}

pub fn canonicalUrlSlice(url: []const u8) []const u8 {
    var s = url;

    if (std.mem.startsWith(u8, s, "https://")) {
        s = s[8..];
    } else if (std.mem.startsWith(u8, s, "http://")) {
        s = s[7..];
    }

    if (std.mem.startsWith(u8, s, "www.")) {
        s = s[4..];
    }

    if (std.mem.indexOfScalar(u8, s, '#')) |idx| {
        s = s[0..idx];
    }
    if (std.mem.indexOfScalar(u8, s, '?')) |idx| {
        s = s[0..idx];
    }

    while (s.len > 0 and s[s.len - 1] == '/') {
        s = s[0 .. s.len - 1];
    }

    return s;
}

pub fn canonicalUrlHash(url: []const u8) u64 {
    const canonical = canonicalUrlSlice(url);
    return std.hash.Wyhash.hash(0, canonical);
}

test "normalize lowercases" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const out = try normalizeAlloc(allocator, "Hello World");
    defer allocator.free(out);
    try testing.expectEqualStrings("hello world", out);
}

test "canonical url stripping" {
    try std.testing.expectEqualStrings("example.com", canonicalUrlSlice("https://example.com"));
    try std.testing.expectEqualStrings("example.com", canonicalUrlSlice("http://example.com"));
    try std.testing.expectEqualStrings("example.com", canonicalUrlSlice("www.example.com"));
    try std.testing.expectEqualStrings("example.com/path", canonicalUrlSlice("example.com/path/"));
    try std.testing.expectEqualStrings("example.com", canonicalUrlSlice("example.com#section"));
    try std.testing.expectEqualStrings("example.com/page", canonicalUrlSlice("example.com/page?a=1&b=2"));
    try std.testing.expectEqualStrings("example.com/path", canonicalUrlSlice("https://www.example.com/path/?q=1#sec"));
}

test "entry constructors set fields" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var history = try Entry.initHistory(allocator, "https://example.com", "Example", 5, 1700000000000);
    defer history.deinit(allocator);
    try testing.expectEqualStrings("https://example.com", history.url);
    try testing.expectEqual(@as(u32, 5), history.visit_count.?);
    try testing.expectEqual(@as(Source, .history), history.source);
    try testing.expectEqualStrings("example", history.title_norm);

    var bookmark = try Entry.initBookmark(allocator, "https://example.com", "Example", "Work / Projects");
    defer bookmark.deinit(allocator);
    try testing.expectEqualStrings("Work / Projects", bookmark.folder.?);
    try testing.expectEqual(@as(Source, .bookmark), bookmark.source);

    var tab = try Entry.initTab(allocator, "https://example.com", "Example", 42);
    defer tab.deinit(allocator);
    try testing.expectEqual(@as(i32, 42), tab.tab_id.?);
    try testing.expectEqual(@as(Source, .tab), tab.source);
}

test "source ordering" {
    const testing = std.testing;
    try testing.expect(@intFromEnum(Source.tab) > @intFromEnum(Source.bookmark));
    try testing.expect(@intFromEnum(Source.bookmark) > @intFromEnum(Source.history));
}
