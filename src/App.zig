//! Scout application orchestration.

const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const Config = @import("Config.zig");
const Dir = @import("Dir.zig");
const Herdr = @import("Herdr.zig");
const Matcher = @import("picker/Matcher.zig");
const Projects = @import("Projects.zig");
const Tmux = @import("Tmux.zig");
const Ui = @import("picker/Ui.zig");

arena: Allocator,
io: std.Io,
home: ?[]const u8,
environ_map: *std.process.Environ.Map,

const SessionSource = union(enum) {
    none,
    tmux,
    herdr: Herdr,
};

const LoadRequest = struct {
    app: Self,
    root_path: []const u8,
    session_source: SessionSource,
};

const WorkerFutures = struct {
    discovery: std.Io.Future(void),
    sessions: ?std.Io.Future(void),
    cleanup_complete: bool = false,
};

const BatchEmitter = struct {
    loop: *vaxis.Loop(Ui.Event),
    arena: Allocator,
    workspaces: []const Herdr.Workspace = &.{},

    pub fn emitBatch(self: *BatchEmitter, batch: *Projects.Batch) !void {
        if (batch.workspace_id == null and self.workspaces.len > 0) {
            var names: std.ArrayList([]const u8) = .empty;
            for (batch.names) |name| {
                const exists = for (self.workspaces) |workspace| {
                    if (std.mem.eql(u8, name, workspace.label)) break true;
                } else false;
                if (!exists) try names.append(self.arena, name);
            }
            batch.names = try names.toOwnedSlice(self.arena);
            if (batch.names.len == 0) return;
        }
        try self.loop.postEvent(.{ .batch = batch });
    }
};

const DirectCollector = struct {
    query: []const u8,
    exact_match: ?[]const u8 = null,
    fuzzy_match: ?[]const u8 = null,
    fuzzy_match_count: u2 = 0,

    pub fn emitBatch(self: *DirectCollector, batch: *const Projects.Batch) !void {
        for (batch.names) |name| {
            if (std.mem.eql(u8, self.query, name)) {
                self.exact_match = name;
                continue;
            }

            if (self.fuzzy_match_count < 2 and Matcher.matches(self.query, name)) {
                self.fuzzy_match = self.fuzzy_match orelse name;
                self.fuzzy_match_count += 1;
            }
        }
    }

    fn result(self: DirectCollector) DirectSelectionError![]const u8 {
        if (self.exact_match) |name| return name;
        if (self.fuzzy_match_count == 0) return error.NoMatch;
        if (self.fuzzy_match_count > 1) return error.AmbiguousMatch;
        return self.fuzzy_match.?;
    }
};

const DirectSelectionError = error{
    NoMatch,
    AmbiguousMatch,
};

pub fn init(
    arena: Allocator,
    io: std.Io,
    home: ?[]const u8,
    environ_map: *std.process.Environ.Map,
) Self {
    return .{
        .arena = arena,
        .io = io,
        .home = home,
        .environ_map = environ_map,
    };
}

pub fn pickPath(self: Self, root_path: []const u8) !?[]const u8 {
    const selection = try self.pick(root_path, .none, null) orelse return null;

    const path = try self.selectionPath(selection);
    return path;
}

/// Selects a unique query match or opens the picker with the query entered.
pub fn pickPathQuery(self: Self, root_path: []const u8, query: []const u8) !?[]const u8 {
    return self.pathForQuery(root_path, query, .none);
}

fn directPath(self: Self, root_path: []const u8, query: []const u8) ![]const u8 {
    if (query.len == 0) return error.NoMatch;

    var directory = try Dir.openAbsolute(
        self.arena,
        self.io,
        self.home,
        root_path,
    );
    defer directory.close();

    var collector: DirectCollector = .{ .query = query };
    try Projects.discoverBatches(self.arena, directory, &collector);

    const project_name = try collector.result();

    return std.mem.concat(self.arena, u8, &.{ directory.path, project_name });
}

/// Opens a project through tmux after selecting it from the configured root.
pub fn openTmuxProjectQuery(
    self: Self,
    root_path: []const u8,
    query: ?[]const u8,
    tmux: Config.Mode.Tmux,
) !void {
    const project_path = try self.projectPathForQuery(root_path, query, .tmux) orelse return;

    if (tmux.inside) {
        try Tmux.replaceSwitch(self.io, project_path);
    } else {
        try Tmux.replaceSession(self.io, project_path);
    }
}

/// Opens a project through Herdr after selecting it from the configured root.
pub fn openHerdrProjectQuery(
    self: Self,
    root_path: []const u8,
    query: ?[]const u8,
    config: Config.Mode.Herdr,
) !void {
    const herdr = try Herdr.init(self.arena, self.io, config.socket_path, config.inside, self.home);
    if (query) |value| {
        const workspaces = herdr.listWorkspaces() catch |err| switch (err) {
            error.FileNotFound, error.Unexpected => &.{},
            else => return err,
        };
        const workspace_id = Herdr.workspaceForQuery(workspaces, value) catch
            return self.pickHerdrProject(root_path, value, herdr);
        if (workspace_id) |id| return herdr.focusWorkspace(id);
        const project_path = self.directPath(root_path, value) catch |err| switch (err) {
            error.NoMatch, error.AmbiguousMatch => {
                return self.pickHerdrProject(root_path, value, herdr);
            },
            else => return err,
        };
        return herdr.openProject(project_path);
    }
    return self.pickHerdrProject(root_path, null, herdr);
}

fn pickHerdrProject(self: Self, root_path: []const u8, query: ?[]const u8, herdr: Herdr) !void {
    const selection = try self.pick(root_path, .{ .herdr = herdr }, query) orelse return;
    if (selection.workspace_id) |id| return herdr.focusWorkspace(id);
    try herdr.openProject(try self.selectionPath(selection));
}

fn projectPathForQuery(
    self: Self,
    root_path: []const u8,
    query: ?[]const u8,
    session_source: SessionSource,
) !?[]const u8 {
    const project_path = if (query) |value|
        (try self.pathForQuery(root_path, value, session_source)) orelse return null
    else blk: {
        const selection = try self.pick(root_path, session_source, null) orelse return null;
        break :blk try self.selectionPath(selection);
    };

    return project_path;
}

fn selectionPath(self: Self, selection: Ui.Selection) ![]const u8 {
    return std.mem.concat(self.arena, u8, &.{
        selection.root_path,
        selection.project_name,
    });
}

fn pathForQuery(
    self: Self,
    root_path: []const u8,
    query: []const u8,
    session_source: SessionSource,
) !?[]const u8 {
    return self.directPath(root_path, query) catch |err| switch (err) {
        error.NoMatch, error.AmbiguousMatch => blk: {
            const selection = try self.pick(root_path, session_source, query) orelse
                break :blk null;
            break :blk try self.selectionPath(selection);
        },
        else => return err,
    };
}

fn pick(
    self: Self,
    root_path: []const u8,
    session_source: SessionSource,
    initial_query: ?[]const u8,
) !?Ui.Selection {
    var context: LoadRequest = .{
        .app = self,
        .root_path = root_path,
        .session_source = session_source,
    };

    const picker: Ui = .init(self.arena, self.io, self.environ_map, .{
        .context = &context,
        .start_loading = startWorkers,
    });

    return picker.pickWithQuery(initial_query);
}

fn startWorkers(context_ptr: *anyopaque, loop: *vaxis.Loop(Ui.Event)) !Ui.WorkerHandle {
    const context: *LoadRequest = @ptrCast(@alignCast(context_ptr));
    const owner = try context.app.arena.create(WorkerFutures);

    var discovery = try context.app.io.concurrent(discoveryWorker, .{ context, loop });
    errdefer discovery.cancel(context.app.io);

    const sessions = switch (context.session_source) {
        .none => null,
        else => try context.app.io.concurrent(sessionWorker, .{ context, loop }),
    };

    owner.* = .{ .discovery = discovery, .sessions = sessions };
    if (sessions == null) {
        try loop.postEvent(.{
            .sessions = .{ .names = .empty },
        });
    }

    return .{
        .opaque_context = owner,
        .cancel_and_await_fn = cancelAndAwaitWorkers,
    };
}

fn cancelAndAwaitWorkers(owner_ptr: *anyopaque, io: std.Io) void {
    const owner: *WorkerFutures = @ptrCast(@alignCast(owner_ptr));
    if (owner.cleanup_complete) return;

    // Future.cancel is an idempotent cancellation request followed by await.
    owner.discovery.cancel(io);
    if (owner.sessions) |*future| future.cancel(io);

    owner.cleanup_complete = true;
}

fn discoveryWorker(context: *LoadRequest, loop: *vaxis.Loop(Ui.Event)) void {
    const result = discover(context, loop);
    loop.postEvent(.{ .discovery_result = result }) catch return;
}

fn discover(context: *LoadRequest, loop: *vaxis.Loop(Ui.Event)) !void {
    var emitter: BatchEmitter = .{ .loop = loop, .arena = context.app.arena };
    const root_path = try Dir.resolveAbsolutePath(
        context.app.arena,
        context.app.io,
        context.app.home,
        context.root_path,
    );
    if (context.session_source == .herdr) {
        const workspaces = context.session_source.herdr.listWorkspaces() catch |err| switch (err) {
            error.FileNotFound, error.Unexpected => &.{},
            else => return err,
        };
        emitter.workspaces = workspaces;
        for (workspaces) |workspace| {
            const names = try context.app.arena.alloc([]const u8, 1);
            names[0] = workspace.label;
            const batch = try context.app.arena.create(Projects.Batch);
            batch.* = .{
                .root_path = root_path,
                .names = names,
                .workspace_id = workspace.workspace_id,
            };
            try emitter.emitBatch(batch);
        }
    }
    var directory = Dir.openAbsolute(
        context.app.arena,
        context.app.io,
        context.app.home,
        context.root_path,
    ) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.NotDir => {
            if (emitter.workspaces.len > 0) return;
            return err;
        },
        else => return err,
    };
    defer directory.close();

    try Projects.discoverBatches(context.app.arena, directory, &emitter);
}

fn sessionWorker(context: *LoadRequest, loop: *vaxis.Loop(Ui.Event)) void {
    const sessions = sessionNames(context) catch Ui.SessionSet.empty;

    loop.postEvent(.{ .sessions = .{
        .names = sessions,
        .name_normalizer = if (context.session_source == .tmux) Tmux.sessionName else null,
    } }) catch return;
}

fn sessionNames(context: *LoadRequest) !Ui.SessionSet {
    return switch (context.session_source) {
        .none => unreachable,
        .tmux => try Tmux.listSessions(context.app.arena, context.app.io),
        .herdr => |herdr| try herdr.listSessions(context.root_path),
    };
}

test "direct selection prefers an exact name over fuzzy matches" {
    var collector: DirectCollector = .{ .query = "foo" };
    const batch: Projects.Batch = .{
        .root_path = "/projects/",
        .names = &.{ "foo-bar", "foobar", "foo" },
    };

    try collector.emitBatch(&batch);
    try std.testing.expectEqualStrings("foo", try collector.result());
}

test "direct selection accepts one fuzzy match" {
    var collector: DirectCollector = .{ .query = "sct" };
    const batch: Projects.Batch = .{
        .root_path = "/projects/",
        .names = &.{ "source-target", "other" },
    };

    try collector.emitBatch(&batch);
    try std.testing.expectEqualStrings("source-target", try collector.result());
}

test "direct path returns the normalized path for a unique project" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "scout", .default_dir);
    try tmp.dir.createDir(io, "other", .default_dir);

    const root = try std.Io.Dir.path.join(arena, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    const app: Self = .init(arena, io, null, &environ_map);

    const actual = try app.directPath(root, "scout");
    const expected_root = try Dir.resolveAbsolutePath(arena, io, null, root);
    const expected = try std.mem.concat(arena, u8, &.{ expected_root, "scout" });
    try std.testing.expectEqualStrings(expected, actual);
}

test "empty query skips direct selection" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    const app: Self = .init(arena_state.allocator(), io, null, &environ_map);

    try std.testing.expectError(error.NoMatch, app.directPath("missing", ""));
}

test "direct selection rejects zero and multiple fuzzy matches" {
    var no_match: DirectCollector = .{ .query = "missing" };
    try no_match.emitBatch(&.{ .root_path = "/projects/", .names = &.{ "one", "two" } });
    try std.testing.expectError(error.NoMatch, no_match.result());

    var ambiguous: DirectCollector = .{ .query = "app" };
    try ambiguous.emitBatch(&.{
        .root_path = "/projects/",
        .names = &.{ "apple", "application" },
    });
    try std.testing.expectError(error.AmbiguousMatch, ambiguous.result());
}

test {
    _ = Config;
    _ = Dir;
    _ = Herdr;
    _ = Projects;
    _ = Tmux;
    _ = Ui;
}
