//! Kitty remote-control transport for session listing and project tabs.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SessionSet = std.StringHashMapUnmanaged(void);

const SESSION_DIRECTORY = "/tmp/scout/kitty-sessions";
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
listen_on: []const u8,
kitty_pid: []const u8,

pub const InitError = error{ MissingListenOn, InvalidKittyPid };

const LsWindow = struct {
    id: u64,
    session_name: []const u8,
    last_focused_at: f64,
};

const LsTab = struct {
    windows: []const LsWindow,
};

const LsOsWindow = struct {
    tabs: []const LsTab,
};

/// Initializes Kitty interaction over its private remote-control channel.
pub fn init(arena: Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) InitError!Self {
    const listen_on = environ_map.get("KITTY_LISTEN_ON") orelse return error.MissingListenOn;
    if (listen_on.len == 0) return error.MissingListenOn;
    const kitty_pid = environ_map.get("KITTY_PID") orelse return error.InvalidKittyPid;
    if (!valid_kitty_pid(kitty_pid)) return error.InvalidKittyPid;

    return .{
        .arena = arena,
        .io = io,
        .listen_on = listen_on,
        .kitty_pid = kitty_pid,
    };
}

/// Returns the active Kitty session names reported by remote control.
pub fn list_sessions(self: Self) !SessionSet {
    const state = try self.list_state(LIST_TIMEOUT);
    return collect_sessions(self.arena, state);
}

/// Switches to the project's Kitty session, creating it when absent.
pub fn open_project(self: Self, project_path: []const u8) !void {
    const session_path = try self.write_session_file(project_path);
    _ = try self.run(&.{
        "kitten", "@",            "--to",       self.listen_on,
        "action", "goto_session", session_path,
    }, OPEN_TIMEOUT);
}

fn write_session_file(self: Self, project_path: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, project_path, "\r\n") != null) return error.InvalidProjectPath;

    const trimmed_path = std.mem.trimEnd(u8, project_path, std.Io.Dir.path.sep_str);
    const project_name = std.Io.Dir.path.basename(trimmed_path);
    if (project_name.len == 0) return error.InvalidProjectPath;

    const escaped_path = try escape_session_path(self.arena, trimmed_path);
    const contents = try std.fmt.allocPrint(self.arena, "cd {s}\nlaunch\n", .{escaped_path});
    const session_path = try session_file_path(self.arena, self.kitty_pid, project_name);
    const session_directory = std.Io.Dir.path.dirname(session_path) orelse unreachable;
    _ = try std.Io.Dir.cwd().createDirPathStatus(
        self.io,
        session_directory,
        .fromMode(0o700),
    );

    var file = try std.Io.Dir.cwd().createFile(self.io, session_path, .{
        .permissions = .fromMode(0o600),
    });
    defer file.close(self.io);
    try file.setPermissions(self.io, .fromMode(0o600));
    try file.writeStreamingAll(self.io, contents);
    return session_path;
}

fn session_file_path(arena: Allocator, kitty_pid: []const u8, project_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        SESSION_DIRECTORY ++ "/{s}/{s}.session",
        .{ kitty_pid, project_name },
    );
}

fn valid_kitty_pid(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    const pid = std.fmt.parseInt(u32, value, 10) catch return false;
    return pid > 0;
}

fn escape_session_path(arena: Allocator, path: []const u8) ![]const u8 {
    const dollar_count = std.mem.count(u8, path, "$");
    if (dollar_count == 0) return path;

    const escaped = try arena.alloc(u8, path.len + dollar_count);
    var write_index: usize = 0;
    for (path) |byte| {
        escaped[write_index] = byte;
        write_index += 1;
        if (byte == '$') {
            escaped[write_index] = '$';
            write_index += 1;
        }
    }
    return escaped;
}

fn list_state(self: Self, timeout: std.Io.Timeout) ![]const LsOsWindow {
    const output = try self.run(
        &.{ "kitten", "@", "--to", self.listen_on, "ls" },
        timeout,
    );
    return std.json.parseFromSliceLeaky([]const LsOsWindow, self.arena, output, .{
        .ignore_unknown_fields = true,
    });
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

fn collect_sessions(arena: Allocator, state: []const LsOsWindow) !SessionSet {
    var sessions: SessionSet = .empty;
    for (state) |os_window| {
        for (os_window.tabs) |tab| {
            for (tab.windows) |window| {
                if (window.session_name.len > 0) try sessions.put(arena, window.session_name, {});
            }
        }
    }
    return sessions;
}

test "kitty requires a private control channel" {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();

    try std.testing.expectError(error.MissingListenOn, init(std.testing.allocator, std.testing.io, &environ_map));
    try environ_map.put("KITTY_LISTEN_ON", "");
    try std.testing.expectError(error.MissingListenOn, init(std.testing.allocator, std.testing.io, &environ_map));

    try environ_map.put("KITTY_LISTEN_ON", "unix:@scout-1");
    try std.testing.expectError(error.InvalidKittyPid, init(std.testing.allocator, std.testing.io, &environ_map));
    try environ_map.put("KITTY_PID", "../1");
    try std.testing.expectError(error.InvalidKittyPid, init(std.testing.allocator, std.testing.io, &environ_map));
    try environ_map.put("KITTY_PID", "42");
    const kitty = try init(std.testing.allocator, std.testing.io, &environ_map);
    try std.testing.expectEqualStrings("unix:@scout-1", kitty.listen_on);
    try std.testing.expectEqualStrings("42", kitty.kitty_pid);
}

test "Kitty PID is safe for session file names" {
    try std.testing.expect(valid_kitty_pid("1"));
    try std.testing.expect(valid_kitty_pid("4294967295"));
    try std.testing.expect(!valid_kitty_pid("0"));
    try std.testing.expect(!valid_kitty_pid("4294967296"));
    try std.testing.expect(!valid_kitty_pid("1_000"));
}

test "session file path contains the Kitty PID" {
    const path = try session_file_path(std.testing.allocator, "42", "scout");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/scout/kitty-sessions/42/scout.session", path);
}

test "Kitty JSON provides sessions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const state = try std.json.parseFromSliceLeaky([]const LsOsWindow, arena,
        \\[{"ignored":true,"tabs":[
        \\  {"id":2,"windows":[{"id":20,"session_name":"alpha","last_focused_at":1.5}]},
        \\  {"id":5,"windows":[{"id":50,"session_name":"alpha","last_focused_at":8.0}]},
        \\  {"id":7,"windows":[{"id":70,"session_name":"beta","last_focused_at":3.0}]},
        \\  {"id":9,"windows":[{"id":90,"session_name":"","last_focused_at":4.0}]}
        \\]}]
    , .{ .ignore_unknown_fields = true });

    var sessions = try collect_sessions(arena, state);
    defer sessions.deinit(arena);

    try std.testing.expect(sessions.contains("alpha"));
    try std.testing.expect(sessions.contains("beta"));
    try std.testing.expectEqual(@as(usize, 2), sessions.count());
}

test "session paths escape Kitty variable expansion" {
    const escaped = try escape_session_path(std.testing.allocator, "/home/user/price$5");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings(
        "/home/user/price$$5",
        escaped,
    );
}
