//! One-shot tmux session discovery and handoff.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const SessionSet = std.StringHashMapUnmanaged(void);
const name_bytes_max = std.Io.Dir.max_name_bytes;
const response_bytes_max = 1024 * 1024;
const reader_bytes = 4096;

const SessionName = struct {
    // Reserve the first byte so an exact-target '=' prefix can be added
    // without another buffer or allocation.
    buffer: [name_bytes_max + 1]u8,
    len: usize,

    fn init(path: []const u8) SessionName {
        var result: SessionName = undefined;
        result.len = writeSessionName(sessionBase(path), result.buffer[1..]).len;
        return result;
    }

    fn value(self: *const SessionName) []const u8 {
        return self.buffer[1..][0..self.len];
    }

    fn exactTarget(self: *SessionName) []const u8 {
        self.buffer[0] = '=';
        return self.buffer[0 .. self.len + 1];
    }
};

pub fn listSessions(arena: Allocator, io: std.Io) !SessionSet {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "tmux", "list-sessions", "-F", "#{session_name}" },
        .stdout = .pipe,
        .stderr = .ignore,
    });
    errdefer child.kill(io);

    var buffer: [reader_bytes]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buffer);

    const output = reader.interface.allocRemaining(
        arena,
        .limited(response_bytes_max),
    ) catch |err| switch (err) {
        error.StreamTooLong => {
            child.kill(io);
            return .empty;
        },
        else => return err,
    };

    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return .empty;

    return parseSessions(arena, output);
}

pub fn replaceSession(io: std.Io, project_path: []const u8) !void {
    var name_buffer: [name_bytes_max]u8 = undefined;
    const name = sessionName(project_path, &name_buffer);
    const args = [_][]const u8{ "tmux", "new-session", "-A", "-s", name, "-c", project_path };

    return std.process.replace(io, .{ .argv = &args });
}

pub fn replaceSwitch(io: std.Io, project_path: []const u8) !void {
    var name: SessionName = .init(project_path);

    if (try sessionExists(io, &name)) {
        const args = [_][]const u8{ "tmux", "switch-client", "-t", name.value() };
        return std.process.replace(io, .{ .argv = &args });
    }

    const args = [_][]const u8{
        "tmux", "new-session",   "-d", "-s",         name.value(), "-c", project_path,
        ";",    "switch-client", "-t", name.value(),
    };
    return std.process.replace(io, .{ .argv = &args });
}

fn sessionExists(io: std.Io, name: *SessionName) !bool {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "tmux", "has-session", "-t", name.exactTarget() },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer child.kill(io);

    const term = try child.wait(io);
    return term == .exited and term.exited == 0;
}

/// Returns a normalized basename, borrowing `path` when no rewrite is needed
/// and otherwise returning a slice of `buffer`.
pub fn sessionName(path: []const u8, buffer: *[name_bytes_max]u8) []const u8 {
    const base = sessionBase(path);

    if (std.mem.indexOfScalar(u8, base, '.') == null) return base;
    return writeSessionName(base, buffer);
}

fn writeSessionName(base: []const u8, buffer: *[name_bytes_max]u8) []const u8 {
    assert(base.len <= buffer.len);
    @memcpy(buffer[0..base.len], base);
    std.mem.replaceScalar(u8, buffer[0..base.len], '.', '_');

    return buffer[0..base.len];
}

fn sessionBase(path: []const u8) []const u8 {
    return std.Io.Dir.path.basename(
        std.mem.trimEnd(u8, path, std.Io.Dir.path.sep_str),
    );
}

fn parseSessions(arena: Allocator, output: []const u8) !SessionSet {
    var sessions: SessionSet = .empty;
    var lines = std.mem.tokenizeScalar(u8, output, '\n');

    while (lines.next()) |name| try sessions.put(arena, name, {});

    return sessions;
}

test "session normalization and parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [name_bytes_max]u8 = undefined;
    const unchanged = sessionName("/tmp/scout/", &buffer);
    try std.testing.expectEqualStrings("scout", unchanged);
    try std.testing.expectEqualStrings("my_project", sessionName("/tmp/my.project/", &buffer));
    const sessions = try parseSessions(arena.allocator(), "alpha\nbeta\n");
    try std.testing.expect(sessions.contains("alpha"));
    try std.testing.expect(sessions.contains("beta"));

    var name: SessionName = .init("/tmp/my.project/");
    try std.testing.expectEqualStrings("my_project", name.value());
    try std.testing.expectEqualStrings("=my_project", name.exactTarget());
}
