const std = @import("std");
const model = @import("model.zig");

const Entry = model.Entry;
const TAB_CAP: usize = 500;

pub fn loadTabs(allocator: std.mem.Allocator, sessions_dir: []const u8) ![]Entry {
    const newest = try findNewestSessionFile(allocator, sessions_dir);
    defer allocator.free(newest);

    const data = try std.fs.cwd().readFileAlloc(allocator, newest, 16 * 1024 * 1024);
    defer allocator.free(data);

    const tabs = try parseSnss(allocator, data);
    defer {
        for (tabs) |tab| {
            allocator.free(tab.url);
            allocator.free(tab.title);
        }
        allocator.free(tabs);
    }

    var tab_map = std.AutoHashMap(i32, struct { index: i32, url: []const u8, title: []const u8 }).init(allocator);
    defer tab_map.deinit();

    for (tabs) |tab| {
        const gop = try tab_map.getOrPut(tab.id);
        if (!gop.found_existing or tab.index > gop.value_ptr.index) {
            gop.value_ptr.* = .{ .index = tab.index, .url = tab.url, .title = tab.title };
        }
    }

    var out = std.ArrayList(Entry){};
    errdefer out.deinit(allocator);
    var it = tab_map.iterator();
    var count: usize = 0;
    while (it.next()) |kv| {
        if (count >= TAB_CAP) break;
        const entry = try Entry.initTab(allocator, kv.value_ptr.url, kv.value_ptr.title, kv.key_ptr.*);
        try out.append(allocator, entry);
        count += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn findNewestSessionFile(allocator: std.mem.Allocator, sessions_dir: []const u8) ![]u8 {
    var dir = std.fs.openDirAbsolute(sessions_dir, .{ .iterate = true }) catch |err| {
        return switch (err) {
            error.FileNotFound, error.NotDir => error.SessionsMissing,
            else => err,
        };
    };
    defer dir.close();

    var iter = dir.iterate();
    var best: ?Candidate = null;
    while (try iter.next()) |entry| {
        const name = entry.name;
        if (!(std.mem.startsWith(u8, name, "Tabs_") or std.mem.startsWith(u8, name, "Session_"))) continue;
        const is_tabs = std.mem.startsWith(u8, name, "Tabs_");
        const stat: ?std.fs.File.Stat = dir.statFile(name) catch null;
        const mtime: i128 = if (stat) |st| st.mtime else 0;
        const candidate = Candidate{
            .name = try allocator.dupe(u8, name),
            .is_tabs = is_tabs,
            .mtime = mtime,
        };
        if (best) |b| {
            if (shouldReplace(b, candidate)) {
                allocator.free(b.name);
                best = candidate;
            } else {
                allocator.free(candidate.name);
            }
        } else {
            best = candidate;
        }
    }

    const chosen = best orelse return error.NoSessionFiles;
    defer allocator.free(chosen.name);
    return std.fs.path.join(allocator, &.{ sessions_dir, chosen.name });
}

const Candidate = struct {
    name: []const u8,
    is_tabs: bool,
    mtime: i128,
};

fn shouldReplace(current: Candidate, next: Candidate) bool {
    if (next.is_tabs and !current.is_tabs) return true;
    if (!next.is_tabs and current.is_tabs) return false;
    return next.mtime > current.mtime;
}

const Tab = struct {
    id: i32,
    index: i32,
    url: []const u8,
    title: []const u8,
};

fn parseSnss(allocator: std.mem.Allocator, data: []const u8) ![]Tab {
    if (data.len < 8 or !std.mem.eql(u8, data[0..4], "SNSS")) {
        return error.InvalidHeader;
    }
    var offset: usize = 4;
    _ = readInt(i32, data, &offset); // version, unused

    var tabs = std.ArrayList(Tab){};
    errdefer tabs.deinit(allocator);

    while (offset + 2 <= data.len) {
        const len = readInt(u16, data, &offset);
        if (len == 0) break;
        if (offset + len > data.len) break;
        const slice = data[offset .. offset + len];
        offset += len;
        if (slice.len == 0) continue;

        var c_off: usize = 0;
        const id = slice[c_off];
        c_off += 1;
        if (id != 1 and id != 6) continue;
        const maybe_tab = parseTab(allocator, slice, &c_off) catch |err| switch (err) {
            error.UnexpectedEof => continue,
            else => return err,
        };
        if (maybe_tab) |tab| {
            try tabs.append(allocator, tab);
        }
    }

    return tabs.toOwnedSlice(allocator);
}

fn parseTab(allocator: std.mem.Allocator, data: []const u8, pos: *usize) !?Tab {
    var p = pos.*;

    if (p + 4 > data.len) return null;
    p += 4;
    if (p + 8 > data.len) return null;
    const tab_id = readInt(i32, data, &p);
    const index = readInt(i32, data, &p);

    const url = try parsePaddedString(allocator, data, &p);
    const title_utf16 = try parsePaddedSlice(data, &p, true);
    const title = try utf16leToUtf8(allocator, title_utf16);

    // state blob
    _ = try parsePaddedSlice(data, &p, false);

    // transition, post flags
    _ = try readIntOptional(u32, data, &p);
    _ = try readIntOptional(i32, data, &p);

    // referrer url
    _ = try parsePaddedSlice(data, &p, false);
    // reference policy
    _ = try readIntOptional(i32, data, &p);
    // original_request_url
    _ = try parsePaddedSlice(data, &p, false);
    // user agent
    _ = try readIntOptional(i32, data, &p);

    pos.* = p;
    return Tab{ .id = tab_id, .index = index, .url = url, .title = title };
}

fn parsePaddedString(allocator: std.mem.Allocator, data: []const u8, pos: *usize) ![]u8 {
    const slice = try parsePaddedSlice(data, pos, false);
    return allocator.dupe(u8, slice);
}

fn parsePaddedSlice(data: []const u8, pos: *usize, is_utf16: bool) ![]const u8 {
    const len = readInt(u32, data, pos);
    const byte_len = if (is_utf16) len * 2 else len;
    const padded = nextMultipleOf4(byte_len);
    if (pos.* + padded > data.len) return error.UnexpectedEof;
    const slice = data[pos.* .. pos.* + byte_len];
    pos.* += padded;
    return slice;
}

fn readInt(comptime T: type, data: []const u8, pos: *usize) T {
    const size = @sizeOf(T);
    const v = std.mem.readInt(T, data[pos.*..][0..size], .little);
    pos.* += size;
    return v;
}

fn readIntOptional(comptime T: type, data: []const u8, pos: *usize) !T {
    if (pos.* + @sizeOf(T) > data.len) return error.UnexpectedEof;
    return readInt(T, data, pos);
}

fn nextMultipleOf4(v: u32) usize {
    return @intCast((v + 3) & ~@as(u32, 3));
}

fn utf16leToUtf8(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len % 2 != 0) return error.UnexpectedEof;

    const unit_len = bytes.len / 2;
    var code_units = try allocator.alloc(u16, unit_len);
    defer allocator.free(code_units);

    var idx: usize = 0;
    while (idx < unit_len) : (idx += 1) {
        const start = idx * 2;
        const window = bytes[start..][0..2];
        code_units[idx] = std.mem.readInt(u16, window, .little);
    }

    var iter = std.unicode.Utf16LeIterator.init(code_units);
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    while (true) {
        const next = iter.nextCodepoint() catch continue;
        const cp = next orelse break;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch continue;
        try out.appendSlice(allocator, buf[0..len]);
    }
    return out.toOwnedSlice(allocator);
}

// Minimal parser regression
test "parse simple tab entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf = std.ArrayList(u8){};
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "SNSS");
    try buf.appendSlice(alloc, &std.mem.toBytes(@as(i32, 1)));

    var cmd = std.ArrayList(u8){};
    defer cmd.deinit(alloc);
    try cmd.append(alloc, 1);
    try cmd.appendNTimes(alloc, 0, 4);
    try cmd.appendSlice(alloc, &std.mem.toBytes(@as(i32, 123)));
    try cmd.appendSlice(alloc, &std.mem.toBytes(@as(i32, 5)));

    const url = "https://example.com";
    try cmd.appendSlice(alloc, &std.mem.toBytes(@as(u32, url.len)));
    try cmd.appendSlice(alloc, url);
    try cmd.appendNTimes(alloc, 0, nextMultipleOf4(@as(u32, url.len)) - url.len);

    const title_utf16 = [_]u16{ 'E', 'x', 'a', 'm', 'p', 'l', 'e' };
    const title_bytes = std.mem.sliceAsBytes(&title_utf16);
    try cmd.appendSlice(alloc, &std.mem.toBytes(@as(u32, title_utf16.len)));
    try cmd.appendSlice(alloc, title_bytes);
    try cmd.appendNTimes(alloc, 0, nextMultipleOf4(@as(u32, title_bytes.len)) - title_bytes.len);

    try cmd.appendSlice(alloc, &std.mem.toBytes(@as(u32, 0))); // state len
    try cmd.appendSlice(alloc, &std.mem.toBytes(@as(u32, 0))); // transition
    try cmd.appendSlice(alloc, &std.mem.toBytes(@as(i32, 0))); // post
    try cmd.appendSlice(alloc, &std.mem.toBytes(@as(u32, 0))); // referrer len
    try cmd.appendSlice(alloc, &std.mem.toBytes(@as(i32, 0))); // reference policy
    try cmd.appendSlice(alloc, &std.mem.toBytes(@as(u32, 0))); // original_request_url len
    try cmd.appendSlice(alloc, &std.mem.toBytes(@as(i32, 0))); // user agent

    const cmd_len: u16 = @intCast(cmd.items.len);
    try buf.appendSlice(alloc, &std.mem.toBytes(cmd_len));
    try buf.appendSlice(alloc, cmd.items);

    const tabs = try parseSnss(alloc, buf.items);
    defer {
        for (tabs) |tab| {
            alloc.free(tab.url);
            alloc.free(tab.title);
        }
        alloc.free(tabs);
    }
    try std.testing.expectEqual(@as(usize, 1), tabs.len);
    try std.testing.expectEqual(@as(i32, 123), tabs[0].id);
    try std.testing.expectEqualStrings("https://example.com", tabs[0].url);
    try std.testing.expectEqualStrings("Example", tabs[0].title);
}
