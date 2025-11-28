const std = @import("std");
const config = @import("config.zig");
const history = @import("history.zig");
const bookmarks = @import("bookmarks.zig");
const tabs = @import("tabs.zig");
const search = @import("search.zig");
const output = @import("output.zig");
const model = @import("model.zig");
const Entry = model.Entry;

const Allocator = std.mem.Allocator;

pub fn main() !void {
    run() catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: {s}\n", .{@errorName(err)}) catch "error\n";
        _ = std.fs.File.stderr().writeAll(msg) catch {};
        std.process.exit(1);
    };
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    var args = std.process.args();
    _ = args.skip(); // binary name

    const sub = args.next() orelse {
        try printUsage();
        return error.InvalidArgs;
    };

    if (std.mem.eql(u8, sub, "history")) {
        const opts = try parseHistoryArgs(&args, alloc);
        const cfg = try config.Config.init(alloc, opts.profile);
        const history_path = try cfg.historyPath();
        const entries = try history.loadHistory(alloc, history_path, opts.limit);
        if (opts.json) {
            try output.printEntriesArray(entries);
        } else {
            try output.printEntries(entries);
        }
        return;
    }

    if (std.mem.eql(u8, sub, "bookmarks")) {
        const opts = try parseCommonArgs(&args, alloc);
        const cfg = try config.Config.init(alloc, opts.profile);
        const bookmarks_path = try cfg.bookmarksPath();
        const entries = try bookmarks.loadBookmarks(alloc, bookmarks_path);
        if (opts.json) {
            try output.printEntriesArray(entries);
        } else {
            try output.printEntries(entries);
        }
        return;
    }

    if (std.mem.eql(u8, sub, "tabs")) {
        const opts = try parseCommonArgs(&args, alloc);
        const cfg = try config.Config.init(alloc, opts.profile);
        const sessions_dir = try cfg.sessionsDir();
        const entries = tabs.loadTabs(alloc, sessions_dir) catch |err| {
            warn(err);
            const empty: []Entry = &.{};
            if (opts.json) {
                try output.printEntriesArray(empty);
            } else {
                try output.printEntries(empty);
            }
            return;
        };
        if (opts.json) {
            try output.printEntriesArray(entries);
        } else {
            try output.printEntries(entries);
        }
        return;
    }

    if (std.mem.eql(u8, sub, "search")) {
        const opts = try parseSearchArgs(&args, alloc);
        const cfg = try config.Config.init(alloc, opts.profile);

        var all_entries = std.ArrayList(model.Entry){};
        defer all_entries.deinit(alloc);

        if (opts.sources.history) {
            const path = try cfg.historyPath();
            const history_entries = try history.loadHistory(alloc, path, 5000);
            try all_entries.appendSlice(alloc, history_entries);
        }

        if (opts.sources.bookmarks) {
            const path = try cfg.bookmarksPath();
            const bookmark_entries = try bookmarks.loadBookmarks(alloc, path);
            try all_entries.appendSlice(alloc, bookmark_entries);
        }

        if (opts.sources.tabs) {
            const path = try cfg.sessionsDir();
            if (tabs.loadTabs(alloc, path)) |tab_entries| {
                try all_entries.appendSlice(alloc, tab_entries);
            } else |err| {
                warn(err);
            }
        }

        const deduped = try search.dedupeEntries(alloc, all_entries.items);
        var engine = search.SearchEngine.init(alloc);
        const results = try engine.search(deduped, opts.query, opts.limit);

        if (opts.json) {
            try output.printEntriesArray(results);
        } else {
            try output.printSearchResults(results);
        }
        return;
    }

    try printUsage();
    return error.InvalidArgs;
}

fn parseHistoryArgs(args: *std.process.ArgIterator, allocator: Allocator) !struct {
    limit: usize,
    profile: []const u8,
    json: bool,
} {
    var limit: usize = 100;
    var profile = try allocator.dupe(u8, "Default");
    var json = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--limit")) {
            const val = args.next() orelse return error.InvalidArgs;
            limit = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--profile")) {
            const val = args.next() orelse return error.InvalidArgs;
            profile = try allocator.dupe(u8, val);
        } else {
            return error.InvalidArgs;
        }
    }

    return .{ .limit = limit, .profile = profile, .json = json };
}

fn parseCommonArgs(args: *std.process.ArgIterator, allocator: Allocator) !struct {
    profile: []const u8,
    json: bool,
} {
    var profile = try allocator.dupe(u8, "Default");
    var json = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--profile")) {
            const val = args.next() orelse return error.InvalidArgs;
            profile = try allocator.dupe(u8, val);
        } else {
            return error.InvalidArgs;
        }
    }
    return .{ .profile = profile, .json = json };
}

const SearchSources = struct {
    history: bool = true,
    bookmarks: bool = true,
    tabs: bool = true,
};

fn parseSources(s: []const u8) SearchSources {
    var src = SearchSources{ .history = false, .bookmarks = false, .tabs = false };
    var iter = std.mem.splitScalar(u8, s, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (std.mem.eql(u8, trimmed, "history")) src.history = true;
        if (std.mem.eql(u8, trimmed, "bookmarks")) src.bookmarks = true;
        if (std.mem.eql(u8, trimmed, "tabs")) src.tabs = true;
    }
    return src;
}

fn parseSearchArgs(args: *std.process.ArgIterator, allocator: Allocator) !struct {
    query: []const u8,
    all: bool,
    sources: SearchSources,
    limit: usize,
    profile: []const u8,
    json: bool,
} {
    var query: []const u8 = "";
    var all = false;
    var sources = SearchSources{};
    var limit: usize = 50;
    var profile = try allocator.dupe(u8, "Default");
    var json = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-a")) {
            all = true;
        } else if (std.mem.eql(u8, arg, "--sources") or std.mem.eql(u8, arg, "-s")) {
            const val = args.next() orelse return error.InvalidArgs;
            sources = parseSources(val);
        } else if (std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "-l")) {
            const val = args.next() orelse return error.InvalidArgs;
            limit = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, arg, "--profile") or std.mem.eql(u8, arg, "-p")) {
            const val = args.next() orelse return error.InvalidArgs;
            profile = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            query = try allocator.dupe(u8, arg);
        } else {
            return error.InvalidArgs;
        }
    }

    if (query.len == 0 and !all) {
        return error.InvalidArgs;
    }

    return .{
        .query = query,
        .all = all,
        .sources = sources,
        .limit = limit,
        .profile = profile,
        .json = json,
    };
}

fn printUsage() !void {
    const usage =
        \\Usage:
        \\  dia-zig history [--limit N] [--profile P] [--json]
        \\  dia-zig bookmarks [--profile P] [--json]
        \\  dia-zig tabs [--profile P] [--json]
        \\  dia-zig search [QUERY] [--all] [--sources S] [--limit N] [--profile P] [--json]
        \\
    ;
    try std.fs.File.stderr().writeAll(usage);
}

fn warn(err: anyerror) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "warning: {s}\n", .{@errorName(err)}) catch "warning\n";
    _ = std.fs.File.stderr().writeAll(msg) catch {};
}

test "pulls in module tests" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(model);
    std.testing.refAllDecls(@import("history.zig"));
    std.testing.refAllDecls(@import("bookmarks.zig"));
    std.testing.refAllDecls(@import("tabs.zig"));
    std.testing.refAllDecls(@import("search.zig"));
    std.testing.refAllDecls(@import("output.zig"));
    std.testing.refAllDecls(@import("config.zig"));
}
