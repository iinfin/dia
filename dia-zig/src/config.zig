const std = @import("std");

const DIA_DATA_DIR = "Library/Application Support/Dia/User Data";

pub const Config = struct {
    allocator: std.mem.Allocator,
    profile_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, profile: []const u8) !Config {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        errdefer allocator.free(home);

        const data_dir = try std.fs.path.join(allocator, &.{ home, DIA_DATA_DIR });
        errdefer allocator.free(data_dir);

        try ensurePathExists(data_dir, "dia data directory");

        const profile_path = try std.fs.path.join(allocator, &.{ data_dir, profile });
        errdefer allocator.free(profile_path);
        try ensureProfile(allocator, profile_path, data_dir, profile);

        allocator.free(home);
        allocator.free(data_dir);

        return .{ .allocator = allocator, .profile_path = profile_path };
    }

    pub fn historyPath(self: Config) ![]const u8 {
        return std.fs.path.join(self.allocator, &.{ self.profile_path, "History" });
    }

    pub fn bookmarksPath(self: Config) ![]const u8 {
        return std.fs.path.join(self.allocator, &.{ self.profile_path, "Bookmarks" });
    }

    pub fn sessionsDir(self: Config) ![]const u8 {
        return std.fs.path.join(self.allocator, &.{ self.profile_path, "Sessions" });
    }
};

fn ensurePathExists(path: []const u8, label: []const u8) !void {
    std.fs.cwd().access(path, .{}) catch |err| {
        return errorForPath(err, path, label);
    };
}

fn ensureProfile(
    allocator: std.mem.Allocator,
    profile_path: []const u8,
    data_dir: []const u8,
    profile: []const u8,
) !void {
    std.fs.cwd().access(profile_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            const available = try listProfiles(allocator, data_dir);
            defer allocator.free(available);
            if (available.len == 0) {
                return errorForPath(err, profile_path, "profile path");
            }
            var buf: [1024]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "profile '{s}' not found (available: {s})\n",
                .{ profile, available },
            ) catch "profile missing\n";
            _ = std.fs.File.stderr().writeAll(msg) catch {};
            return errorForPath(err, profile_path, "profile path");
        }
        return errorForPath(err, profile_path, "profile path");
    };
}

fn listProfiles(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    var dir = try std.fs.openDirAbsolute(data_dir, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    var first = true;
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        if (!first) try buf.appendSlice(allocator, ", ");
        first = false;
        try buf.appendSlice(allocator, entry.name);
    }

    return try buf.toOwnedSlice(allocator);
}

fn errorForPath(err: anyerror, path: []const u8, label: []const u8) !void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} not found: {s}\n", .{ label, path }) catch "path missing\n";
    _ = std.fs.File.stderr().writeAll(msg) catch {};
    return if (err == error.FileNotFound) error.PathMissing else err;
}
