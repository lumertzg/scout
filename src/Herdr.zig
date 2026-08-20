//! Herdr workspace discovery and handoff over its local socket API.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const Dir = @import("dir.zig");

pub const SessionSet = std.StringHashMapUnmanaged(void);

const REQUEST_ID = "scout";
const RESPONSE_BYTES_MAX = 1024 * 1024;
const SOCKET_BUFFER_BYTES = 4096;
const SESSION_NAME_BYTES_MAX = 64;

const REQUEST_TIMEOUT: std.Io.Timeout = .{ .duration = .{
    .raw = .fromMilliseconds(500),
    .clock = .awake,
} };
const SERVER_START_TIMEOUT_MS = 15_000;
const SERVER_START_RETRY_DELAY_MS = 50;
const SERVER_START_ATTEMPTS = SERVER_START_TIMEOUT_MS / SERVER_START_RETRY_DELAY_MS;
const SERVER_START_RETRY_DELAY: std.Io.Duration = .fromMilliseconds(SERVER_START_RETRY_DELAY_MS);

arena: Allocator,
io: std.Io,
address: std.Io.net.UnixAddress,
inside_herdr: bool,
home: ?[]const u8,

const Pane = struct {
    workspace_id: []const u8,
    cwd: ?[]const u8 = null,
};

const PaneListResult = struct {
    type: []const u8,
    panes: []const Pane,
};

const ResultHeader = struct {
    type: []const u8,
};

const ErrorBody = struct {
    code: []const u8,
    message: []const u8,
};

pub fn init(arena: Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !Self {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;
    const socket_path = try resolve_socket_path(arena, environ_map);

    return .{
        .arena = arena,
        .io = io,
        .address = try .init(socket_path),
        .inside_herdr = std.mem.eql(u8, environ_map.get("HERDR_ENV") orelse "", "1"),
        .home = environ_map.get("HOME"),
    };
}

pub fn list_sessions(self: Self, root_path: []const u8) !SessionSet {
    const root = try Dir.resolve_absolute_path(self.arena, self.io, self.home, root_path);
    const panes = try self.list_panes();
    var sessions: SessionSet = .empty;

    for (panes) |pane| {
        const cwd = pane.cwd orelse continue;
        const name = project_name_from_cwd(root, cwd) orelse continue;
        try sessions.put(self.arena, name, {});
    }

    return sessions;
}

pub fn open_project(self: Self, project_path: []const u8) !void {
    self.open_running_project(project_path) catch |err| switch (err) {
        error.FileNotFound, error.Unexpected => {
            if (self.inside_herdr) return err;
            var launcher = try self.start_server_launcher(project_path);
            errdefer launcher.kill(self.io);
            try self.wait_for_server_and_open(project_path);
            // Bare Herdr detaches the real server before attaching this temporary client.
            launcher.kill(self.io);
            return self.replace_with_herdr();
        },
        else => return err,
    };

    if (!self.inside_herdr) return self.replace_with_herdr();
}

fn open_running_project(self: Self, project_path: []const u8) !void {
    const name = project_name(project_path);
    if (name.len == 0) return error.InvalidProjectPath;

    const panes = try self.list_panes();
    if (workspace_for_project(panes, project_path)) |workspace_id| {
        const response = try self.query("workspace.focus", .{
            .workspace_id = workspace_id,
        });

        return expect_action(self.arena, response, "workspace_info");
    }

    const response = try self.query("workspace.create", .{
        .cwd = project_path,
        .label = name,
        .focus = true,
    });
    try expect_action(self.arena, response, "workspace_created");
}

fn start_server_launcher(self: Self, project_path: []const u8) !std.process.Child {
    return std.process.spawn(self.io, .{
        .argv = &.{"herdr"},
        .cwd = .{ .path = project_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn wait_for_server_and_open(self: Self, project_path: []const u8) !void {
    for (0..SERVER_START_ATTEMPTS) |attempt| {
        self.open_running_project(project_path) catch |err| {
            if (attempt + 1 == SERVER_START_ATTEMPTS) return err;
            try std.Io.sleep(self.io, SERVER_START_RETRY_DELAY, .awake);
            continue;
        };
        return;
    }
}

fn replace_with_herdr(self: Self) !void {
    return std.process.replace(self.io, .{ .argv = &.{"herdr"} });
}

fn list_panes(self: Self) ![]const Pane {
    const response = try self.query("pane.list", .{});
    return parse_pane_list(self.arena, response);
}

fn query(self: Self, method: []const u8, params: anytype) ![]const u8 {
    const stream = try self.address.connect(self.io);
    defer stream.close(self.io);

    var write_buffer: [SOCKET_BUFFER_BYTES]u8 = undefined;
    var writer = stream.writer(self.io, &write_buffer);
    var json: std.json.Stringify = .{
        .writer = &writer.interface,
        .options = .{},
    };

    try json.write(.{
        .id = REQUEST_ID,
        .method = method,
        .params = params,
    });

    try writer.interface.writeByte('\n');
    try writer.interface.flush();

    var response: std.ArrayList(u8) = .empty;
    errdefer response.deinit(self.arena);
    var read_buffer: [SOCKET_BUFFER_BYTES]u8 = undefined;

    while (true) {
        const message = try stream.socket.receiveTimeout(self.io, &read_buffer, REQUEST_TIMEOUT);
        if (message.data.len == 0) return error.UnexpectedEndOfStream;

        const line_end = std.mem.indexOfScalar(u8, message.data, '\n') orelse message.data.len;
        if (line_end > RESPONSE_BYTES_MAX - response.items.len) return error.ResponseTooLarge;

        try response.appendSlice(self.arena, message.data[0..line_end]);
        if (line_end < message.data.len) break;
    }

    return response.toOwnedSlice(self.arena);
}

fn resolve_socket_path(arena: Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    if (environ_map.get("HERDR_SOCKET_PATH")) |path| {
        if (path.len == 0) return error.InvalidSocketPath;
        return path;
    }

    const config_root = if (environ_map.get("XDG_CONFIG_HOME")) |path|
        path
    else if (environ_map.get("HOME")) |home|
        try std.Io.Dir.path.join(arena, &.{ home, ".config" })
    else
        environ_map.get("TMPDIR") orelse "/tmp";

    const session = environ_map.get("HERDR_SESSION") orelse "default";
    if (!std.mem.eql(u8, session, "default")) {
        if (!valid_session_name(session)) return error.InvalidSessionName;

        return std.Io.Dir.path.join(arena, &.{
            config_root,
            "herdr",
            "sessions",
            session,
            "herdr.sock",
        });
    }

    return std.Io.Dir.path.join(arena, &.{ config_root, "herdr", "herdr.sock" });
}

fn valid_session_name(name: []const u8) bool {
    if (name.len == 0 or name.len > SESSION_NAME_BYTES_MAX) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;

    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            byte != '.' and byte != '_' and byte != '-') return false;
    }
    return true;
}

fn project_name(path: []const u8) []const u8 {
    return std.Io.Dir.path.basename(std.mem.trimEnd(u8, path, std.Io.Dir.path.sep_str));
}

fn project_name_from_cwd(root_path: []const u8, cwd: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, cwd, root_path)) return null;

    const relative = cwd[root_path.len..];
    if (relative.len == 0) return null;

    const name_end = std.mem.indexOfAny(u8, relative, std.Io.Dir.path.sep_str) orelse relative.len;
    if (name_end == 0) return null;

    return relative[0..name_end];
}

fn workspace_for_project(panes: []const Pane, project_path: []const u8) ?[]const u8 {
    const normalized_project_path = trim_path_end(project_path);

    for (panes) |pane| {
        const cwd = pane.cwd orelse continue;

        if (path_is_within(trim_path_end(cwd), normalized_project_path)) {
            return pane.workspace_id;
        }
    }

    return null;
}

fn trim_path_end(path: []const u8) []const u8 {
    return std.mem.trimEnd(u8, path, std.Io.Dir.path.sep_str);
}

fn path_is_within(path: []const u8, parent: []const u8) bool {
    if (std.mem.eql(u8, path, parent)) return true;
    if (!std.mem.startsWith(u8, path, parent) or path.len <= parent.len) return false;
    return std.Io.Dir.path.isSep(path[parent.len]);
}

fn parse_pane_list(arena: Allocator, response: []const u8) ![]const Pane {
    const result = try parse_response(PaneListResult, arena, response);
    if (!std.mem.eql(u8, result.type, "pane_list")) return error.InvalidResponse;

    return result.panes;
}

fn expect_action(arena: Allocator, response: []const u8, expected_type: []const u8) !void {
    const result = try parse_response(ResultHeader, arena, response);
    if (!std.mem.eql(u8, result.type, expected_type)) return error.InvalidResponse;
}

fn parse_response(comptime Result: type, arena: Allocator, response: []const u8) !Result {
    const Envelope = struct {
        id: []const u8,
        result: ?Result = null,
        @"error": ?ErrorBody = null,
    };

    const envelope = try std.json.parseFromSliceLeaky(Envelope, arena, response, .{
        .ignore_unknown_fields = true,
    });

    if (!std.mem.eql(u8, envelope.id, REQUEST_ID)) return error.InvalidResponse;
    if (envelope.@"error" != null) return error.HerdrRequestFailed;

    return envelope.result orelse error.InvalidResponse;
}

test "socket path follows Herdr environment precedence" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();

    try environ_map.put("HOME", "/home/user");
    try std.testing.expectEqualStrings(
        "/home/user/.config/herdr/herdr.sock",
        try resolve_socket_path(arena, &environ_map),
    );

    try environ_map.put("XDG_CONFIG_HOME", "/config");
    try environ_map.put("HERDR_SESSION", "work");
    try std.testing.expectEqualStrings(
        "/config/herdr/sessions/work/herdr.sock",
        try resolve_socket_path(arena, &environ_map),
    );

    try environ_map.put("HERDR_SOCKET_PATH", "/tmp/herdr.sock");
    try std.testing.expectEqualStrings(
        "/tmp/herdr.sock",
        try resolve_socket_path(arena, &environ_map),
    );
}

test "socket path rejects unsafe session names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("HOME", "/home/user");
    try environ_map.put("HERDR_SESSION", "../other");

    try std.testing.expectError(
        error.InvalidSessionName,
        resolve_socket_path(arena_state.allocator(), &environ_map),
    );
}

test "socket path follows Herdr temporary fallback without home" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();

    try std.testing.expectEqualStrings(
        "/tmp/herdr/herdr.sock",
        try resolve_socket_path(arena, &environ_map),
    );

    try environ_map.put("TMPDIR", "/var/tmp");
    try std.testing.expectEqualStrings(
        "/var/tmp/herdr/herdr.sock",
        try resolve_socket_path(arena, &environ_map),
    );
}

test "pane list response provides workspace paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const panes = try parse_pane_list(arena_state.allocator(),
        \\{"id":"scout","result":{"type":"pane_list","panes":[
        \\  {"pane_id":"w1:p1","workspace_id":"w1","cwd":"/home/user/scout","ignored":true},
        \\  {"pane_id":"w2:p1","workspace_id":"w2","cwd":"/home/user/zig"}
        \\]}}
    );
    try std.testing.expectEqual(@as(usize, 2), panes.len);
    try std.testing.expectEqualStrings("w1", panes[0].workspace_id);
    try std.testing.expectEqualStrings("/home/user/scout", panes[0].cwd.?);
    try std.testing.expectEqualStrings(
        "w2",
        workspace_for_project(panes, "/home/user/zig").?,
    );
    try std.testing.expectEqualStrings(
        "w1",
        workspace_for_project(panes, "/home/user/scout/").?,
    );
}

test "project matching requires a path boundary" {
    const panes = [_]Pane{
        .{ .workspace_id = "w1", .cwd = "/home/user/api-client/src" },
        .{ .workspace_id = "w2", .cwd = "/home/user/api/tests" },
    };

    try std.testing.expectEqualStrings("w2", workspace_for_project(&panes, "/home/user/api").?);
    try std.testing.expect(workspace_for_project(&panes, "/home/user/other") == null);
}

test "active project name comes from cwd under the configured root" {
    try std.testing.expectEqualStrings(
        "scout",
        project_name_from_cwd("/home/user/Projects/", "/home/user/Projects/scout/src").?,
    );
    try std.testing.expect(project_name_from_cwd(
        "/home/user/Projects/",
        "/home/user/Projects-other/scout",
    ) == null);
    try std.testing.expect(project_name_from_cwd(
        "/home/user/Projects/",
        "/home/user/Projects/",
    ) == null);
}

test "action response validates result type and errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expect_action(arena,
        \\{"id":"scout","result":{"type":"workspace_info","workspace":{}}}
    , "workspace_info");
    try std.testing.expectError(
        error.HerdrRequestFailed,
        expect_action(arena,
            \\{"id":"scout","error":{"code":"not_found","message":"missing"}}
        , "workspace_info"),
    );
}
