//! One-shot tmux session discovery and handoff.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const SessionSet = std.StringHashMapUnmanaged(void);
const NAME_BYTES_MAX = std.Io.Dir.max_name_bytes;
const RESPONSE_BYTES_MAX = 1024 * 1024;
const READER_BYTES = 4096;

const SessionName = struct {
    // Reserve the first byte so an exact-target '=' prefix can be added
    // without another buffer or allocation.
    buffer: [NAME_BYTES_MAX + 1]u8,
    len: usize,

    fn init(path: []const u8) SessionName {
        var result: SessionName = undefined;
        result.len = write_session_name(session_base(path), result.buffer[1..]).len;
        return result;
    }

    fn value(self: *const SessionName) []const u8 {
        return self.buffer[1..][0..self.len];
    }

    fn exact_target(self: *SessionName) []const u8 {
        self.buffer[0] = '=';
        return self.buffer[0 .. self.len + 1];
    }
};

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
    var name_buffer: [NAME_BYTES_MAX]u8 = undefined;
    const name = session_name(project_path, &name_buffer);
    const args = [_][]const u8{ "tmux", "new-session", "-A", "-s", name, "-c", project_path };

    return std.process.replace(io, .{ .argv = &args });
}

pub fn replace_switch(io: std.Io, project_path: []const u8) !void {
    var name: SessionName = .init(project_path);

    if (try session_exists(io, &name)) {
        const args = [_][]const u8{ "tmux", "switch-client", "-t", name.value() };
        return std.process.replace(io, .{ .argv = &args });
    }

    const args = [_][]const u8{ "tmux", "new-session", "-d", "-s", name.value(), "-c", project_path, ";", "switch-client", "-t", name.value() };
    return std.process.replace(io, .{ .argv = &args });
}

fn session_exists(io: std.Io, name: *SessionName) !bool {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "tmux", "has-session", "-t", name.exact_target() },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(io);

    const term = try child.wait(io);
    return term == .exited and term.exited == 0;
}

/// Returns a normalized basename, borrowing `path` when no rewrite is needed
/// and otherwise returning a slice of `buffer`.
pub fn session_name(path: []const u8, buffer: *[NAME_BYTES_MAX]u8) []const u8 {
    const base = session_base(path);

    if (std.mem.indexOfScalar(u8, base, '.') == null) return base;
    return write_session_name(base, buffer);
}

fn write_session_name(base: []const u8, buffer: *[NAME_BYTES_MAX]u8) []const u8 {
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
    var buffer: [NAME_BYTES_MAX]u8 = undefined;
    const unchanged = session_name("/tmp/scout/", &buffer);
    try std.testing.expectEqualStrings("scout", unchanged);
    try std.testing.expectEqualStrings("my_project", session_name("/tmp/my.project/", &buffer));
    const sessions = try parse_sessions(arena.allocator(), "alpha\nbeta\n");
    try std.testing.expect(sessions.contains("alpha"));
    try std.testing.expect(sessions.contains("beta"));

    var name: SessionName = .init("/tmp/my.project/");
    try std.testing.expectEqualStrings("my_project", name.value());
    try std.testing.expectEqualStrings("=my_project", name.exact_target());
}
