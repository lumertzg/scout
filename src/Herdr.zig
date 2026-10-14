//! Herdr workspace discovery and handoff over its local socket API.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const Dir = @import("Dir.zig");
const Matcher = @import("picker/Matcher.zig");

pub const SessionSet = std.StringHashMapUnmanaged(void);

const request_id = "scout";
const response_bytes_max = 1024 * 1024;
const socket_buffer_bytes = 4096;
const session_name_bytes_max = 64;

const request_timeout: std.Io.Timeout = .{ .duration = .{
    .raw = .fromMilliseconds(500),
    .clock = .awake,
} };
const server_start_timeout_ms = 15_000;
const server_start_retry_delay_ms = 50;
const server_start_attempts = server_start_timeout_ms / server_start_retry_delay_ms;
const server_start_retry_delay: std.Io.Duration = .fromMilliseconds(server_start_retry_delay_ms);

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

pub const Workspace = struct {
    workspace_id: []const u8,
    label: []const u8,
    worktree: ?struct {
        checkout_path: []const u8,
    } = null,
};

const WorkspaceListResult = struct {
    type: []const u8,
    workspaces: []const Workspace,
};

const ResultHeader = struct {
    type: []const u8,
};

const ErrorBody = struct {
    code: []const u8,
    message: []const u8,
};

pub fn init(
    arena: Allocator,
    io: std.Io,
    socket_path: []const u8,
    inside_herdr: bool,
    home: ?[]const u8,
) !Self {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;

    return .{
        .arena = arena,
        .io = io,
        .address = try .init(socket_path),
        .inside_herdr = inside_herdr,
        .home = home,
    };
}

pub fn listWorkspaces(self: Self) ![]const Workspace {
    const response = try self.query("workspace.list", .{});
    const result = try parseResponse(WorkspaceListResult, self.arena, response);
    if (!std.mem.eql(u8, result.type, "workspace_list")) return error.InvalidResponse;
    return result.workspaces;
}

pub fn focusWorkspace(self: Self, workspace_id: []const u8) !void {
    try self.focusRunningWorkspace(workspace_id);
    if (!self.inside_herdr) try self.replaceWithHerdr();
}

pub fn workspaceForQuery(workspaces: []const Workspace, query_text: []const u8) !?[]const u8 {
    if (query_text.len == 0) return null;
    var exact: ?[]const u8 = null;
    var exact_count: usize = 0;
    var fuzzy: ?[]const u8 = null;
    var fuzzy_count: usize = 0;
    for (workspaces) |workspace| {
        if (std.mem.eql(u8, workspace.label, query_text)) {
            exact = workspace.workspace_id;
            exact_count += 1;
        } else if (Matcher.matches(query_text, workspace.label)) {
            fuzzy = workspace.workspace_id;
            fuzzy_count += 1;
        }
    }
    if (exact_count > 1) return error.AmbiguousMatch;
    if (exact) |id| return id;
    if (fuzzy_count > 1) return error.AmbiguousMatch;
    return fuzzy;
}

pub fn listSessions(self: Self, root_path: []const u8) !SessionSet {
    const root = try Dir.resolveAbsolutePath(self.arena, self.io, self.home, root_path);
    const workspaces = try self.listWorkspaces();
    const needs_panes = for (workspaces) |workspace| {
        if (workspace.worktree == null) break true;
    } else false;
    const panes = if (needs_panes) try self.listPanes() else &.{};
    var sessions: SessionSet = .empty;

    for (workspaces) |workspace| {
        try sessions.put(self.arena, workspace.label, {});
        if (workspace.worktree) |worktree| {
            const name = projectNameFromCwd(root, worktree.checkout_path) orelse continue;
            try sessions.put(self.arena, name, {});
        } else {
            for (panes) |pane| {
                if (!std.mem.eql(u8, pane.workspace_id, workspace.workspace_id)) continue;
                const cwd = pane.cwd orelse continue;
                const name = projectNameFromCwd(root, cwd) orelse continue;
                try sessions.put(self.arena, name, {});
            }
        }
    }

    return sessions;
}

pub fn openProject(self: Self, project_path: []const u8) !void {
    self.openRunningProject(project_path) catch |err| switch (err) {
        error.FileNotFound, error.Unexpected => {
            if (self.inside_herdr) return err;
            var launcher = try self.startServerLauncher(project_path);
            errdefer launcher.kill(self.io);
            try self.waitForServerAndOpen(project_path);
            // Bare Herdr detaches the real server before attaching this temporary client.
            launcher.kill(self.io);
            return self.replaceWithHerdr();
        },
        else => return err,
    };

    if (!self.inside_herdr) return self.replaceWithHerdr();
}

fn focusRunningWorkspace(self: Self, workspace_id: []const u8) !void {
    const response = try self.query("workspace.focus", .{ .workspace_id = workspace_id });
    try expectAction(self.arena, response, "workspace_info");
}

fn openRunningProject(self: Self, project_path: []const u8) !void {
    const name = projectName(project_path);
    if (name.len == 0) return error.InvalidProjectPath;

    const workspaces = try self.listWorkspaces();
    var matching_id: ?[]const u8 = null;
    for (workspaces) |workspace| {
        if (std.mem.eql(u8, workspace.label, name)) {
            if (matching_id != null) return error.AmbiguousMatch;
            matching_id = workspace.workspace_id;
        }
    }
    if (matching_id) |id| return self.focusRunningWorkspace(id);

    for (workspaces) |workspace| {
        const worktree = workspace.worktree orelse continue;
        if (std.mem.eql(u8, trimPathEnd(worktree.checkout_path), trimPathEnd(project_path))) {
            if (matching_id != null) return error.AmbiguousMatch;
            matching_id = workspace.workspace_id;
        }
    }
    if (matching_id) |id| return self.focusRunningWorkspace(id);

    const panes = try self.listPanes();
    if (try workspaceForProject(panes, project_path)) |workspace_id| {
        return self.focusRunningWorkspace(workspace_id);
    }

    const response = try self.query("workspace.create", .{
        .cwd = project_path,
        .label = name,
        .focus = true,
    });
    try expectAction(self.arena, response, "workspace_created");
}

fn startServerLauncher(self: Self, project_path: []const u8) !std.process.Child {
    return std.process.spawn(self.io, .{
        .argv = &.{"herdr"},
        .cwd = .{ .path = project_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn waitForServerAndOpen(self: Self, project_path: []const u8) !void {
    for (0..server_start_attempts) |attempt| {
        self.openRunningProject(project_path) catch |err| {
            if (attempt + 1 == server_start_attempts) return err;
            try std.Io.sleep(self.io, server_start_retry_delay, .awake);
            continue;
        };
        return;
    }
}

fn replaceWithHerdr(self: Self) !void {
    return std.process.replace(self.io, .{ .argv = &.{"herdr"} });
}

fn listPanes(self: Self) ![]const Pane {
    const response = try self.query("pane.list", .{});
    return parsePaneList(self.arena, response);
}

fn query(self: Self, method: []const u8, params: anytype) ![]const u8 {
    const stream = try self.address.connect(self.io);
    defer stream.close(self.io);

    var write_buffer: [socket_buffer_bytes]u8 = undefined;
    var writer = stream.writer(self.io, &write_buffer);
    var json: std.json.Stringify = .{
        .writer = &writer.interface,
        .options = .{},
    };

    try json.write(.{
        .id = request_id,
        .method = method,
        .params = params,
    });

    try writer.interface.writeByte('\n');
    try writer.interface.flush();

    var response: std.ArrayList(u8) = .empty;
    errdefer response.deinit(self.arena);
    var read_buffer: [socket_buffer_bytes]u8 = undefined;

    while (true) {
        const message = try stream.socket.receiveTimeout(self.io, &read_buffer, request_timeout);
        if (message.data.len == 0) return error.UnexpectedEndOfStream;

        const line_end = std.mem.indexOfScalar(u8, message.data, '\n') orelse message.data.len;
        if (line_end > response_bytes_max - response.items.len) return error.ResponseTooLarge;

        try response.appendSlice(self.arena, message.data[0..line_end]);
        if (line_end < message.data.len) break;
    }

    return response.toOwnedSlice(self.arena);
}

/// Resolves the socket path selected by the Herdr environment.
pub fn resolveSocketPath(
    arena: Allocator,
    environ_map: *const std.process.Environ.Map,
) ![]const u8 {
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
        if (!validSessionName(session)) return error.InvalidSessionName;

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

fn validSessionName(name: []const u8) bool {
    if (name.len == 0 or name.len > session_name_bytes_max) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;

    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            byte != '.' and byte != '_' and byte != '-') return false;
    }
    return true;
}

fn projectName(path: []const u8) []const u8 {
    return std.Io.Dir.path.basename(std.mem.trimEnd(u8, path, std.Io.Dir.path.sep_str));
}

fn projectNameFromCwd(root_path: []const u8, cwd: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, cwd, root_path)) return null;

    const relative = cwd[root_path.len..];
    if (relative.len == 0) return null;

    const name_end = std.mem.indexOfAny(u8, relative, std.Io.Dir.path.sep_str) orelse relative.len;
    if (name_end == 0) return null;

    return relative[0..name_end];
}

fn workspaceForProject(panes: []const Pane, project_path: []const u8) !?[]const u8 {
    const normalized_project_path = trimPathEnd(project_path);
    var workspace_id: ?[]const u8 = null;

    for (panes) |pane| {
        const cwd = pane.cwd orelse continue;

        if (pathIsWithin(trimPathEnd(cwd), normalized_project_path)) {
            if (workspace_id) |id| {
                if (!std.mem.eql(u8, id, pane.workspace_id)) return error.AmbiguousMatch;
            }
            workspace_id = pane.workspace_id;
        }
    }

    return workspace_id;
}

fn trimPathEnd(path: []const u8) []const u8 {
    return std.mem.trimEnd(u8, path, std.Io.Dir.path.sep_str);
}

fn pathIsWithin(path: []const u8, parent: []const u8) bool {
    if (std.mem.eql(u8, path, parent)) return true;
    if (!std.mem.startsWith(u8, path, parent) or path.len <= parent.len) return false;
    return std.Io.Dir.path.isSep(path[parent.len]);
}

fn parsePaneList(arena: Allocator, response: []const u8) ![]const Pane {
    const result = try parseResponse(PaneListResult, arena, response);
    if (!std.mem.eql(u8, result.type, "pane_list")) return error.InvalidResponse;

    return result.panes;
}

fn expectAction(arena: Allocator, response: []const u8, expected_type: []const u8) !void {
    const result = try parseResponse(ResultHeader, arena, response);
    if (!std.mem.eql(u8, result.type, expected_type)) return error.InvalidResponse;
}

fn parseResponse(comptime Result: type, arena: Allocator, response: []const u8) !Result {
    const Envelope = struct {
        id: []const u8,
        result: ?Result = null,
        @"error": ?ErrorBody = null,
    };

    const envelope = try std.json.parseFromSliceLeaky(Envelope, arena, response, .{
        .ignore_unknown_fields = true,
    });

    if (!std.mem.eql(u8, envelope.id, request_id)) return error.InvalidResponse;
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
        try resolveSocketPath(arena, &environ_map),
    );

    try environ_map.put("XDG_CONFIG_HOME", "/config");
    try environ_map.put("HERDR_SESSION", "work");
    try std.testing.expectEqualStrings(
        "/config/herdr/sessions/work/herdr.sock",
        try resolveSocketPath(arena, &environ_map),
    );

    try environ_map.put("HERDR_SOCKET_PATH", "/tmp/herdr.sock");
    try std.testing.expectEqualStrings(
        "/tmp/herdr.sock",
        try resolveSocketPath(arena, &environ_map),
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
        resolveSocketPath(arena_state.allocator(), &environ_map),
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
        try resolveSocketPath(arena, &environ_map),
    );

    try environ_map.put("TMPDIR", "/var/tmp");
    try std.testing.expectEqualStrings(
        "/var/tmp/herdr/herdr.sock",
        try resolveSocketPath(arena, &environ_map),
    );
}

test "pane list response provides workspace paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const panes = try parsePaneList(arena_state.allocator(),
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
        (try workspaceForProject(panes, "/home/user/zig")).?,
    );
    try std.testing.expectEqualStrings(
        "w1",
        (try workspaceForProject(panes, "/home/user/scout/")).?,
    );
}

test "project matching requires a path boundary" {
    const panes = [_]Pane{
        .{ .workspace_id = "w1", .cwd = "/home/user/api-client/src" },
        .{ .workspace_id = "w2", .cwd = "/home/user/api/tests" },
    };

    try std.testing.expectEqualStrings("w2", (try workspaceForProject(&panes, "/home/user/api")).?);
    try std.testing.expect(try workspaceForProject(&panes, "/home/user/other") == null);
}

test "active project name comes from cwd under the configured root" {
    try std.testing.expectEqualStrings(
        "scout",
        projectNameFromCwd("/home/user/Projects/", "/home/user/Projects/scout/src").?,
    );
    try std.testing.expect(projectNameFromCwd(
        "/home/user/Projects/",
        "/home/user/Projects-other/scout",
    ) == null);
    try std.testing.expect(projectNameFromCwd(
        "/home/user/Projects/",
        "/home/user/Projects/",
    ) == null);
}

test "action response validates result type and errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectAction(arena,
        \\{"id":"scout","result":{"type":"workspace_info","workspace":{}}}
    , "workspace_info");
    try std.testing.expectError(
        error.HerdrRequestFailed,
        expectAction(arena,
            \\{"id":"scout","error":{"code":"not_found","message":"missing"}}
        , "workspace_info"),
    );
}
