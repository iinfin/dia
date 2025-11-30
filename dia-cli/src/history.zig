const std = @import("std");
const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

const model = @import("model.zig");

const Entry = model.Entry;
const CHROMIUM_EPOCH_OFFSET: i64 = 11644473600000000;

pub fn loadHistory(
    allocator: std.mem.Allocator,
    history_path: []const u8,
    limit: usize,
) ![]Entry {
    var db: ?*sqlite.sqlite3 = null;
    const uri_noz = try std.fmt.allocPrint(allocator, "file:{s}?immutable=1", .{history_path});
    defer allocator.free(uri_noz);
    const uri = try allocator.alloc(u8, uri_noz.len + 1);
    defer allocator.free(uri);
    std.mem.copyForwards(u8, uri[0..uri_noz.len], uri_noz);
    uri[uri_noz.len] = 0;

    const flags = sqlite.SQLITE_OPEN_READONLY | sqlite.SQLITE_OPEN_URI;
    if (sqlite.sqlite3_open_v2(uri.ptr, &db, flags, null) != sqlite.SQLITE_OK) {
        return error.DatabaseOpenFailed;
    }
    defer _ = sqlite.sqlite3_close(db);

    const query =
        "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT ?1";

    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db, query, -1, &stmt, null) != sqlite.SQLITE_OK) {
        return error.QueryPrepareFailed;
    }
    const statement = stmt orelse return error.QueryPrepareFailed;
    defer _ = sqlite.sqlite3_finalize(statement);

    const climit: c_int = @intCast(@min(limit, @as(usize, @intCast(std.math.maxInt(c_int)))));
    _ = sqlite.sqlite3_bind_int(statement, 1, climit);

    var entries = std.ArrayListUnmanaged(Entry){};
    errdefer entries.deinit(allocator);

    while (sqlite.sqlite3_step(statement) == sqlite.SQLITE_ROW) {
        const url_ptr = sqlite.sqlite3_column_text(statement, 0) orelse continue;
        const url_len = @as(usize, @intCast(sqlite.sqlite3_column_bytes(statement, 0)));
        const url = url_ptr[0..url_len];

        const title_slice: []const u8 = blk: {
            if (sqlite.sqlite3_column_type(statement, 1) == sqlite.SQLITE_NULL) break :blk "";
            const ptr = sqlite.sqlite3_column_text(statement, 1) orelse break :blk "";
            const len = @as(usize, @intCast(sqlite.sqlite3_column_bytes(statement, 1)));
            break :blk ptr[0..len];
        };

        const visit_raw = sqlite.sqlite3_column_int64(statement, 2);
        const visit_count = std.math.cast(u32, visit_raw) orelse std.math.maxInt(u32);
        const chromium_time = sqlite.sqlite3_column_int64(statement, 3);
        const last_visit = chromiumToUnixMs(chromium_time);

        const entry = try Entry.initHistory(allocator, url, title_slice, visit_count, last_visit);
        try entries.append(allocator, entry);
    }

    return entries.toOwnedSlice(allocator);
}

pub fn chromiumToUnixMs(chromium_time: i64) i64 {
    return std.math.divTrunc(i64, chromium_time - CHROMIUM_EPOCH_OFFSET, 1000) catch 0;
}

// tests
test "chromium epoch conversion" {
    const chromium = 13344480000000000;
    try std.testing.expectEqual(@as(i64, 1700006400000), chromiumToUnixMs(chromium));
}

fn createTestDb(path: []const u8) !void {
    var db: ?*sqlite.sqlite3 = null;
    const zpath = try std.fmt.allocPrint(std.testing.allocator, "{s}\x00", .{path});
    defer std.testing.allocator.free(zpath);
    if (sqlite.sqlite3_open(zpath.ptr, &db) != sqlite.SQLITE_OK) return error.DbCreateFailed;
    defer _ = sqlite.sqlite3_close(db);

    const create_stmt =
        "CREATE TABLE urls (url TEXT NOT NULL, title TEXT, visit_count INTEGER DEFAULT 0, last_visit_time INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0);";
    _ = sqlite.sqlite3_exec(db, create_stmt, null, null, null);
}

fn insertEntry(path: []const u8, url: []const u8, title: []const u8, visits: i64, time: i64, hidden: bool) !void {
    var db: ?*sqlite.sqlite3 = null;
    const zpath = try std.fmt.allocPrint(std.testing.allocator, "{s}\x00", .{path});
    defer std.testing.allocator.free(zpath);
    if (sqlite.sqlite3_open(zpath.ptr, &db) != sqlite.SQLITE_OK) return error.DbCreateFailed;
    defer _ = sqlite.sqlite3_close(db);

    const stmt = try std.fmt.allocPrint(
        std.testing.allocator,
        "INSERT INTO urls (url, title, visit_count, last_visit_time, hidden) VALUES ('{s}', '{s}', {d}, {d}, {d});",
        .{ url, title, visits, time, @as(i64, if (hidden) 1 else 0) },
    );
    defer std.testing.allocator.free(stmt);
    _ = sqlite.sqlite3_exec(db, stmt.ptr, null, null, null);
}

test "load history basic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "History" });
    defer std.testing.allocator.free(path);

    try createTestDb(path);
    try insertEntry(path, "https://example.com", "Example", 5, 13344480000000000, false);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const entries = try loadHistory(alloc, path, 10);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("https://example.com", entries[0].url);
    try std.testing.expectEqual(@as(u32, 5), entries[0].visit_count.?);
}
