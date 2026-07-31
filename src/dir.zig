//! Absolute directory handle with its normalized path.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

io: std.Io,
handle: std.Io.Dir,
path: []const u8,

/// Resolves `source_path` absolutely and opens it for iteration.
pub fn open_absolute(arena: Allocator, io: std.Io, home: ?[]const u8, source_path: []const u8) !Self {
    const path = try format_path(arena, io, home, source_path);
    return .{
        .io = io,
        .handle = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }),
        .path = path,
    };
}

pub fn close(self: *Self) void {
    self.handle.close(self.io);
    self.* = undefined;
}

/// Appends the separator needed to concatenate a project name.
fn format_path(arena: Allocator, io: std.Io, home: ?[]const u8, source_path: []const u8) ![]const u8 {
    const expanded_path = try expand_home(arena, home, source_path);

    const absolute_path = if (std.Io.Dir.path.isAbsolute(expanded_path))
        expanded_path
    else blk: {
        const cwd = try std.process.currentPathAlloc(io, arena);
        break :blk try std.Io.Dir.path.resolve(arena, &.{ cwd, expanded_path });
    };

    if (absolute_path.len > 0 and std.Io.Dir.path.isSep(absolute_path[absolute_path.len - 1])) {
        return absolute_path;
    }

    return std.mem.concat(arena, u8, &.{ absolute_path, std.Io.Dir.path.sep_str });
}

fn expand_home(arena: Allocator, home: ?[]const u8, source_path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, source_path, "~")) {
        return home orelse error.HomeNotSet;
    }

    if (source_path.len > 1 and source_path[0] == '~' and std.Io.Dir.path.isSep(source_path[1])) {
        return std.Io.Dir.path.join(arena, &.{ home orelse return error.HomeNotSet, source_path[2..] });
    }

    return source_path;
}

test "opens a home-relative path absolutely" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const relative_path = try std.Io.Dir.path.join(arena, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
    });
    const cwd = try std.process.currentPathAlloc(std.testing.io, arena);
    const home = try std.Io.Dir.path.resolve(arena, &.{ cwd, relative_path });

    var directory = try open_absolute(arena, std.testing.io, home, "~");
    defer directory.close();

    try std.testing.expect(std.Io.Dir.path.isAbsolute(directory.path));
    try std.testing.expect(std.Io.Dir.path.isSep(directory.path[directory.path.len - 1]));
}

test "requires HOME only for tilde expansion" {
    try std.testing.expectError(error.HomeNotSet, expand_home(std.testing.allocator, null, "~/Projects"));
    try std.testing.expectEqualStrings("/tmp/dev", try expand_home(std.testing.allocator, null, "/tmp/dev"));
}
