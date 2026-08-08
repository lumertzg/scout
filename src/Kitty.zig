//! Kitty remote-control transport for session listing and project tabs.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

pub const SessionSet = std.StringHashMapUnmanaged(void);

const SESSION_DIRECTORY = "/tmp/scout/kitty-sessions";
const RESPONSE_BYTES_MAX = 1024 * 1024;
const SOCKET_BUFFER_BYTES = 4096;

// Match the protocol version sent by Kitty's own remote-control client. This is
// independent of the installed Kitty release version.
const KITTY_PROTOCOL_VERSION = "[0,26,0]";
const LIST_REQUEST = "\x1bP@kitty-cmd{\"cmd\":\"ls\",\"version\":" ++
    KITTY_PROTOCOL_VERSION ++ "}\x1b\\";
const RESPONSE_PREFIX = "\x1bP@kitty-cmd";
const RESPONSE_SUFFIX = "\x1b\\";

const LIST_TIMEOUT: std.Io.Timeout = .{ .duration = .{
    .raw = .fromMilliseconds(250),
    .clock = .awake,
} };

arena: Allocator,
io: std.Io,
listen_on: []const u8,
kitty_pid: []const u8,

pub const InitError = error{
    MissingListenOn,
    InvalidKittyPid,
};

const LsWindow = struct {
    session_name: []const u8,
};

const LsTab = struct {
    windows: []const LsWindow,
};

const LsOsWindow = struct {
    tabs: []const LsTab,
};

const ResponseEnvelope = struct {
    ok: bool,
    data: ?[]const u8 = null,
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
    const state = try self.list_state();
    return collect_sessions(self.arena, state);
}

/// Replaces Scout with Kitty's session handoff command.
pub fn replace_project(self: Self, project_path: []const u8) !void {
    const session_path = try self.write_session_file(project_path);
    const args = handoff_args(self.listen_on, session_path);

    return std.process.replace(self.io, .{ .argv = &args });
}

fn handoff_args(listen_on: []const u8, session_path: []const u8) [7][]const u8 {
    return .{
        "kitten",
        "@",
        "--to",
        listen_on,
        "action",
        "goto_session",
        session_path,
    };
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

fn list_state(self: Self) ![]const LsOsWindow {
    var abstract_path: [std.Io.net.UnixAddress.max_len]u8 = undefined;
    const address = try unix_address(self.listen_on, &abstract_path);
    const response = try query_socket(self.arena, self.io, address);
    const data = try response_data(self.arena, response);

    return std.json.parseFromSliceLeaky([]const LsOsWindow, self.arena, data, .{
        .ignore_unknown_fields = true,
    });
}

fn unix_address(listen_on: []const u8, abstract_path: *[std.Io.net.UnixAddress.max_len]u8) !std.Io.net.UnixAddress {
    const prefix = "unix:";
    if (!std.mem.startsWith(u8, listen_on, prefix)) return error.UnsupportedListenAddress;

    const path = listen_on[prefix.len..];
    if (path.len == 0) return error.InvalidListenAddress;

    if (path[0] != '@') return std.Io.net.UnixAddress.init(path);
    if (builtin.os.tag != .linux) return error.UnsupportedListenAddress;
    if (path.len > abstract_path.len) return error.NameTooLong;

    abstract_path[0] = 0;
    @memcpy(abstract_path[1..path.len], path[1..]);
    return std.Io.net.UnixAddress.init(abstract_path[0..path.len]);
}

fn query_socket(arena: Allocator, io: std.Io, address: std.Io.net.UnixAddress) ![]const u8 {
    const stream = if (builtin.os.tag == .linux and address.isAbstract())
        try connect_abstract_linux(address)
    else
        try address.connect(io);

    defer stream.close(io);

    var write_buffer: [LIST_REQUEST.len]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(LIST_REQUEST);
    try writer.interface.flush();

    var response: std.ArrayList(u8) = .empty;
    errdefer response.deinit(arena);
    var read_buffer: [SOCKET_BUFFER_BYTES]u8 = undefined;

    while (true) {
        const message = try stream.socket.receiveTimeout(io, &read_buffer, LIST_TIMEOUT);
        if (message.data.len == 0) return error.UnexpectedEndOfStream;
        if (message.data.len > RESPONSE_BYTES_MAX - response.items.len) {
            return error.ResponseTooLarge;
        }

        try response.appendSlice(arena, message.data);
        if (std.mem.endsWith(u8, response.items, RESPONSE_SUFFIX)) break;
    }

    return response.toOwnedSlice(arena);
}

fn connect_abstract_linux(address: std.Io.net.UnixAddress) !std.Io.net.Stream {
    const linux = std.os.linux;
    const socket_result = linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
    );
    if (linux.errno(socket_result) != .SUCCESS) return error.SocketCreateFailed;

    const socket: std.Io.net.Socket.Handle = @intCast(socket_result);
    errdefer _ = linux.close(socket);

    var socket_address: linux.sockaddr.un = .{
        .path = [_]u8{0} ** @sizeOf(@FieldType(linux.sockaddr.un, "path")),
    };
    @memcpy(socket_address.path[0..address.path.len], address.path);

    const address_len: linux.socklen_t = @intCast(
        @offsetOf(linux.sockaddr.un, "path") + address.path.len,
    );

    while (true) {
        switch (linux.errno(linux.connect(socket, &socket_address, address_len))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.SocketConnectFailed,
        }
    }

    return .{ .socket = .{
        .handle = socket,
        .address = .{ .ip4 = .loopback(0) },
    } };
}

fn response_data(arena: Allocator, response: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, response, RESPONSE_PREFIX)) return error.InvalidResponse;
    if (!std.mem.endsWith(u8, response, RESPONSE_SUFFIX)) return error.InvalidResponse;

    const json = response[RESPONSE_PREFIX.len .. response.len - RESPONSE_SUFFIX.len];
    const envelope = try std.json.parseFromSliceLeaky(ResponseEnvelope, arena, json, .{
        .ignore_unknown_fields = true,
    });
    if (!envelope.ok) return error.RemoteControlFailed;

    return envelope.data orelse error.MissingResponseData;
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

test "Kitty listen address supports filesystem and abstract Unix sockets" {
    var abstract_path: [std.Io.net.UnixAddress.max_len]u8 = undefined;

    const filesystem = try unix_address("unix:/tmp/scout", &abstract_path);
    try std.testing.expectEqualStrings("/tmp/scout", filesystem.path);
    try std.testing.expect(!filesystem.isAbstract());

    if (builtin.os.tag == .linux) {
        const abstract = try unix_address("unix:@scout", &abstract_path);
        try std.testing.expect(abstract.isAbstract());
        try std.testing.expectEqualSlices(u8, "\x00scout", abstract.path);
    } else {
        try std.testing.expectError(
            error.UnsupportedListenAddress,
            unix_address("unix:@scout", &abstract_path),
        );
    }

    try std.testing.expectError(
        error.UnsupportedListenAddress,
        unix_address("tcp:localhost:5000", &abstract_path),
    );
}

test "Kitty protocol response contains list JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const response = RESPONSE_PREFIX ++
        "{\"ok\":true,\"data\":\"[{\\\"tabs\\\":[]}]\"}" ++
        RESPONSE_SUFFIX;
    const data = try response_data(arena_state.allocator(), response);
    try std.testing.expectEqualStrings("[{\"tabs\":[]}]", data);

    try std.testing.expectError(
        error.InvalidResponse,
        response_data(arena_state.allocator(), "not a Kitty response"),
    );
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

test "Kitty handoff arguments use goto_session" {
    const args = handoff_args("unix:@scout", "/tmp/scout.session");
    const expected = [_][]const u8{
        "kitten", "@", "--to", "unix:@scout", "action", "goto_session", "/tmp/scout.session",
    };
    try std.testing.expectEqualSlices([]const u8, &expected, &args);
}
