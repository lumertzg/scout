//! One-shot tmux session discovery and handoff.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const SessionSet = std.StringHashMapUnmanaged(void);
const RESPONSE_BYTES_MAX = 1024 * 1024;
const READER_BYTES = 4096;

pub fn list_sessions(arena: Allocator, io: std.Io) !SessionSet {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "tmux", "list-sessions", "-F", "#{session_name}" },
        .stdout = .pipe,
        .stderr = .ignore,
    });
    errdefer child.kill(io);

    var buffer: [READER_BYTES]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buffer);

    const output = reader.interface.allocRemaining(arena, .limited(RESPONSE_BYTES_MAX)) catch |err| switch (err) {
        error.StreamTooLong => {
            child.kill(io);
            return .empty;
        },
        else => return err,
    };

    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return .empty;

    return parse_sessions(arena, output);
}

pub fn replace_session(io: std.Io, project_path: []const u8) !void {
    var name_buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;

    const name = session_name_buffered(project_path, &name_buffer);
    const args = outside_args(name, project_path);

    return std.process.replace(io, .{ .argv = &args });
}

pub fn replace_switch(io: std.Io, project_path: []const u8) !void {
    var name_buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;

    const name = session_name_buffered(project_path, &name_buffer);
    const args = inside_args(name, project_path);

    return std.process.replace(io, .{ .argv = &args });
}

fn outside_args(name: []const u8, path: []const u8) [7][]const u8 {
    return .{
        "tmux",
        "new-session",
        "-A",
        "-s",
        name,
        "-c",
        path,
    };
}

fn inside_args(name: []const u8, path: []const u8) [11][]const u8 {
    return .{
        "tmux",
        "new-session",
        "-Ad",
        "-s",
        name,
        "-c",
        path,
        ";",
        "switch-client",
        "-t",
        name,
    };
}

pub fn session_name_buffered(path: []const u8, buffer: *[std.Io.Dir.max_name_bytes]u8) []const u8 {
    const base = session_base(path);

    if (std.mem.indexOfScalar(u8, base, '.') == null) return base;
    assert(base.len <= buffer.len);

    @memcpy(buffer[0..base.len], base);
    std.mem.replaceScalar(u8, buffer[0..base.len], '.', '_');

    return buffer[0..base.len];
}

fn session_base(path: []const u8) []const u8 {
    return std.Io.Dir.path.basename(
        std.mem.trimEnd(u8, path, std.Io.Dir.path.sep_str),
    );
}

fn parse_sessions(arena: Allocator, output: []const u8) !SessionSet {
    var sessions: SessionSet = .empty;
    var lines = std.mem.tokenizeScalar(u8, output, '\n');

    while (lines.next()) |name| try sessions.put(arena, name, {});

    return sessions;
}

test "session normalization and parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;
    const unchanged = session_name_buffered("/tmp/scout/", &buffer);
    try std.testing.expectEqualStrings("scout", unchanged);
    try std.testing.expectEqualStrings("my_project", session_name_buffered("/tmp/my.project/", &buffer));
    const sessions = try parse_sessions(arena.allocator(), "alpha\nbeta\n");
    try std.testing.expect(sessions.contains("alpha"));
    try std.testing.expect(sessions.contains("beta"));
}

test "handoff arguments use one tmux invocation" {
    const outside = outside_args("my_project", "/projects/my.project");
    const expected_outside = [_][]const u8{
        "tmux", "new-session", "-A", "-s", "my_project", "-c", "/projects/my.project",
    };
    try std.testing.expectEqualSlices([]const u8, &expected_outside, &outside);

    const inside = inside_args("name", "/p");
    const expected_inside = [_][]const u8{
        "tmux", "new-session", "-Ad", "-s", "name", "-c", "/p", ";", "switch-client", "-t", "name",
    };
    try std.testing.expectEqualSlices([]const u8, &expected_inside, &inside);
}
