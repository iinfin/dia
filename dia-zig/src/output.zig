const std = @import("std");
const model = @import("model.zig");

const Entry = model.Entry;

pub fn printEntries(entries: []const Entry) !void {
    var out = std.io.Writer.Allocating.init(std.heap.page_allocator);
    defer out.deinit();

    for (entries) |entry| {
        var js = std.json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
        try js.write(entry);
        try out.writer.writeByte('\n');
    }

    try std.fs.File.stdout().writeAll(out.written());
}

pub fn printEntriesArray(entries: []const Entry) !void {
    var out = std.io.Writer.Allocating.init(std.heap.page_allocator);
    defer out.deinit();

    var js = std.json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    try js.beginArray();
    for (entries) |entry| {
        try js.write(entry);
    }
    try js.endArray();

    try std.fs.File.stdout().writeAll(out.written());
}

pub const SearchResult = struct {
    results: []const Entry,
    count: usize,

    pub fn jsonStringify(self: SearchResult, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("results");
        try jw.write(self.results);
        try jw.objectField("count");
        try jw.write(self.count);
        try jw.endObject();
    }
};

pub fn printSearchResults(entries: []const Entry) !void {
    var out = std.io.Writer.Allocating.init(std.heap.page_allocator);
    defer out.deinit();

    var js = std.json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    try js.write(SearchResult{ .results = entries, .count = entries.len });

    try std.fs.File.stdout().writeAll(out.written());
}
