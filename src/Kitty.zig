//! Kitty custom-kitten transport for session listing and switching.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SessionSet = std.StringHashMapUnmanaged(void);

const KITTEN_NAME = "scout.py";
const RESPONSE_BYTES_MAX = 1024 * 1024;
const STDERR_BYTES_MAX = 64 * 1024;
const LIST_TIMEOUT: std.Io.Timeout = .{ .duration = .{
    .raw = .fromSeconds(2),
    .clock = .awake,
} };
const OPEN_TIMEOUT: std.Io.Timeout = .{ .duration = .{
    .raw = .fromSeconds(5),
    .clock = .awake,
} };

arena: Allocator,
io: std.Io,
has_private_control: bool,

/// Initializes Kitty interaction without contacting Kitty.
pub fn init(arena: Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) Self {
    return .{
        .arena = arena,
        .io = io,
        .has_private_control = environ_map.get("KITTY_LISTEN_ON") != null,
    };
}

/// Returns the active Kitty session names reported by the custom kitten.
pub fn list_sessions(self: Self) !SessionSet {
    const output = try self.run(
        &.{ "kitten", "@", "kitten", KITTEN_NAME, "--list" },
        LIST_TIMEOUT,
    );
    return parse_sessions(self.arena, output);
}

/// Returns whether session listing can run while the picker owns the TTY.
pub fn can_list_sessions_concurrently(self: Self) bool {
    return self.has_private_control;
}

/// Asks the custom kitten to create or switch to `project_path`.
pub fn open_project(self: Self, project_path: []const u8) !void {
    _ = try self.run(&.{
        "kitten",
        "@",
        "kitten",
        KITTEN_NAME,
        "--open",
        project_path,
    }, OPEN_TIMEOUT);
}

fn run(self: Self, argv: []const []const u8, timeout: std.Io.Timeout) ![]const u8 {
    const result = try std.process.run(self.arena, self.io, .{
        .argv = argv,
        .stdout_limit = .limited(RESPONSE_BYTES_MAX),
        .stderr_limit = .limited(STDERR_BYTES_MAX),
        .timeout = timeout,
    });
    if (result.term != .exited or result.term.exited != 0) return error.RemoteControlFailed;
    return result.stdout;
}

fn parse_sessions(arena: Allocator, output: []const u8) !SessionSet {
    var sessions: SessionSet = .empty;
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |name| {
        try sessions.put(arena, name, {});
    }
    return sessions;
}

test "kitty command uses the custom kitten" {
    try std.testing.expectEqualStrings("scout.py", KITTEN_NAME);
}

test "session output is parsed into a set" {
    var sessions = try parse_sessions(std.testing.allocator, "alpha\nbeta\nalpha\n");
    defer sessions.deinit(std.testing.allocator);

    try std.testing.expect(sessions.contains("alpha"));
    try std.testing.expect(sessions.contains("beta"));
    try std.testing.expectEqual(@as(usize, 2), sessions.count());
}
