const std = @import("std");
const model = @import("model.zig");

const Entry = model.Entry;

pub fn printEntries(entries: []const Entry) !void {
    var buffer: [4096]u8 = undefined;
    var file = std.fs.File.stdout();
    var writer = file.writer(&buffer);
    defer writer.interface.flush() catch {};
    const stream = &writer.interface;

    for (entries) |entry| {
        var js = std.json.Stringify{ .writer = stream, .options = .{ .emit_null_optional_fields = false } };
        try js.write(entry);
        try stream.writeByte('\n');
    }
}

pub fn printEntriesArray(entries: []const Entry) !void {
    var buffer: [4096]u8 = undefined;
    var file = std.fs.File.stdout();
    var writer = file.writer(&buffer);
    defer writer.interface.flush() catch {};
    const stream = &writer.interface;

    var js = std.json.Stringify{ .writer = stream, .options = .{ .emit_null_optional_fields = false } };
    try js.beginArray();
    for (entries) |entry| {
        try js.write(entry);
    }
    try js.endArray();
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
    var buffer: [4096]u8 = undefined;
    var file = std.fs.File.stdout();
    var writer = file.writer(&buffer);
    defer writer.interface.flush() catch {};
    const stream = &writer.interface;

    var js = std.json.Stringify{ .writer = stream, .options = .{ .emit_null_optional_fields = false } };
    try js.write(SearchResult{ .results = entries, .count = entries.len });
}
