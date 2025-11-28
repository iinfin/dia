const std = @import("std");
const model = @import("model.zig");

const Entry = model.Entry;

const BookmarkFile = struct {
    roots: BookmarkRoots,
};

const BookmarkRoots = struct {
    bookmark_bar: ?BookmarkNode = null,
    other: ?BookmarkNode = null,
    synced: ?BookmarkNode = null,
};

const BookmarkNode = struct {
    name: ?[]const u8 = null,
    type: ?[]const u8 = null,
    url: ?[]const u8 = null,
    children: ?[]BookmarkNode = null,
};

const MAX_BOOKMARKS = 10_000;

pub fn loadBookmarks(allocator: std.mem.Allocator, path: []const u8) ![]Entry {
    var file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc(Entry, 0),
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(BookmarkFile, allocator, data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var entries = std.ArrayListUnmanaged(Entry){};
    errdefer entries.deinit(allocator);

    if (parsed.value.roots.bookmark_bar) |node| {
        try flattenNode(allocator, node, "", &entries);
    }
    if (parsed.value.roots.other) |node| {
        try flattenNode(allocator, node, "", &entries);
    }
    if (parsed.value.roots.synced) |node| {
        try flattenNode(allocator, node, "", &entries);
    }

    return entries.toOwnedSlice(allocator);
}

fn flattenNode(
    allocator: std.mem.Allocator,
    node: BookmarkNode,
    folder_path: []const u8,
    entries: *std.ArrayListUnmanaged(Entry),
) !void {
    if (entries.items.len >= MAX_BOOKMARKS) return;

    const node_type = node.type orelse "unknown";
    if (std.mem.eql(u8, node_type, "url")) {
        if (node.url) |url| {
            if (node.name) |title| {
                const folder = if (folder_path.len == 0) null else folder_path;
                try entries.append(allocator, try Entry.initBookmark(allocator, url, title, folder));
            }
        }
        return;
    }

    if (!std.mem.eql(u8, node_type, "folder")) return;

    const path_for_children = try buildFolderPath(allocator, folder_path, node.name);
    defer allocator.free(path_for_children);

    if (node.children) |children| {
        for (children) |child| {
            try flattenNode(allocator, child, path_for_children, entries);
        }
    }
}

fn buildFolderPath(
    allocator: std.mem.Allocator,
    base: []const u8,
    name: ?[]const u8,
) ![]u8 {
    if (name) |n| {
        if (base.len == 0) {
            return allocator.dupe(u8, n);
        }
        return std.fmt.allocPrint(allocator, "{s} / {s}", .{ base, n });
    }
    return allocator.dupe(u8, base);
}

// tests
fn writeFixture(dir: std.fs.Dir, name: []const u8, content: []const u8) !void {
    try dir.writeFile(.{ .sub_path = name, .data = content });
}

test "load bookmarks basic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "Bookmarks" });
    defer std.testing.allocator.free(path);

    const json =
        \\{
        \\  "roots": {
        \\    "bookmark_bar": {
        \\      "type": "folder",
        \\      "name": "Bookmarks Bar",
        \\      "children": [
        \\        {"type": "url", "url": "https://example.com", "name": "Example"}
        \\      ]
        \\    },
        \\    "other": {"type": "folder", "children": []},
        \\    "synced": {"type": "folder", "children": []}
        \\  }
        \\}
    ;
    try writeFixture(tmp.dir, "Bookmarks", json);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = try loadBookmarks(alloc, path);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("https://example.com", entries[0].url);
    try std.testing.expectEqualStrings("Example", entries[0].title);
}

test "load bookmarks nested folders" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "Bookmarks" });
    defer std.testing.allocator.free(path);

    const json =
        \\{
        \\  "roots": {
        \\    "bookmark_bar": {
        \\      "type": "folder",
        \\      "name": "Bar",
        \\      "children": [
        \\        {
        \\          "type": "folder",
        \\          "name": "Work",
        \\          "children": [
        \\            {"type": "url", "url": "https://jira.com", "name": "Jira"}
        \\          ]
        \\        }
        \\      ]
        \\    }
        \\  }
        \\}
    ;
    try writeFixture(tmp.dir, "Bookmarks", json);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = try loadBookmarks(alloc, path);
    try std.testing.expectEqualStrings("Bar / Work", entries[0].folder.?);
}

test "load bookmarks missing file returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const entries = try loadBookmarks(alloc, "/nonexistent/bookmarks");
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}
