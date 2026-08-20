//! Scout application orchestration.

const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const TerminalBackend = @import("Backend.zig").TerminalBackend;
const Dir = @import("dir.zig");
const Herdr = @import("Herdr.zig");
const Matcher = @import("picker/Matcher.zig");
const Projects = @import("Projects.zig");
const Tmux = @import("Tmux.zig");
const Ui = @import("picker/Ui.zig");

arena: Allocator,
io: std.Io,
home: ?[]const u8,
inside_tmux: bool,
environ_map: *std.process.Environ.Map,

const SessionSource = union(enum) {
    none,
    tmux,
    herdr: Herdr,
};

const LoadContext = struct {
    app: Self,
    root_path: []const u8,
    session_source: SessionSource,
};

const WorkerFutures = struct {
    discovery: std.Io.Future(void),
    sessions: ?std.Io.Future(void),
    cleanup_complete: bool = false,
};

const EmitContext = struct {
    loop: *vaxis.Loop(Ui.Event),
    pub fn emit_batch(self: *EmitContext, batch: *Projects.Batch) !void {
        try self.loop.postEvent(.{ .batch = batch });
    }
};

const DirectCollector = struct {
    query: []const u8,
    exact_match: ?[]const u8 = null,
    fuzzy_match: ?[]const u8 = null,
    fuzzy_match_count: u2 = 0,

    pub fn emit_batch(self: *DirectCollector, batch: *const Projects.Batch) !void {
        for (batch.names) |name| {
            if (std.mem.eql(u8, self.query, name)) {
                self.exact_match = name;
                continue;
            }

            if (Matcher.rank(self.query, name) != null and self.fuzzy_match_count < 2) {
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

pub fn init(arena: Allocator, io: std.Io, environ_map: *std.process.Environ.Map) Self {
    return .{
        .arena = arena,
        .io = io,
        .home = environ_map.get("HOME"),
        .inside_tmux = environ_map.get("TMUX") != null,
        .environ_map = environ_map,
    };
}

pub fn pick_path(self: Self, root_path: []const u8) !?[]const u8 {
    const selection = try self.pick(root_path, .none, null) orelse return null;

    return self.selection_path(selection);
}

/// Selects a unique query match or opens the picker with the query entered.
pub fn pick_path_query(self: Self, root_path: []const u8, query: []const u8) !?[]const u8 {
    return self.path_for_query(root_path, query, .none);
}

fn direct_path(self: Self, root_path: []const u8, query: []const u8) ![]const u8 {
    if (query.len == 0) return error.NoMatch;

    var directory = try Dir.open_absolute(
        self.arena,
        self.io,
        self.home,
        root_path,
    );
    defer directory.close();

    var collector: DirectCollector = .{ .query = query };
    try Projects.discover_batches(self.arena, directory, &collector);

    const project_name = try collector.result();

    return std.mem.concat(self.arena, u8, &.{ directory.path, project_name });
}

pub fn open_project(self: Self, root_path: []const u8, backend: TerminalBackend) !void {
    return self.open_project_query(root_path, null, backend);
}

/// Opens a unique positional-query match or uses the interactive picker.
pub fn open_project_query(
    self: Self,
    root_path: []const u8,
    query: ?[]const u8,
    backend: TerminalBackend,
) !void {
    const session_source: SessionSource = switch (backend) {
        .tmux => .tmux,
        .herdr => .{ .herdr = try .init(self.arena, self.io, self.environ_map) },
    };

    const project_path = if (query) |value|
        (try self.path_for_query(root_path, value, session_source)) orelse return
    else blk: {
        const selection = try self.pick(root_path, session_source, null) orelse return;
        break :blk try self.selection_path(selection);
    };

    switch (session_source) {
        .none => unreachable,
        .tmux => if (self.inside_tmux)
            try Tmux.replace_switch(self.io, project_path)
        else
            try Tmux.replace_session(self.io, project_path),
        .herdr => |herdr| try herdr.open_project(project_path),
    }
}

fn selection_path(self: Self, selection: Ui.Selection) ![]const u8 {
    return std.mem.concat(self.arena, u8, &.{
        selection.root_path,
        selection.project_name,
    });
}

fn path_for_query(self: Self, root_path: []const u8, query: []const u8, session_source: SessionSource) !?[]const u8 {
    return self.direct_path(root_path, query) catch |err| switch (err) {
        error.NoMatch, error.AmbiguousMatch => blk: {
            const selection = try self.pick(root_path, session_source, query) orelse break :blk null;
            break :blk try self.selection_path(selection);
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
    var context: LoadContext = .{
        .app = self,
        .root_path = root_path,
        .session_source = session_source,
    };

    const picker: Ui = .init(self.arena, self.io, self.environ_map, .{
        .context = &context,
        .start_loading = start_workers,
    });

    return picker.pick_with_query(initial_query);
}

fn start_workers(context_ptr: *anyopaque, loop: *vaxis.Loop(Ui.Event)) !Ui.WorkerHandle {
    const context: *LoadContext = @ptrCast(@alignCast(context_ptr));
    const owner = try context.app.arena.create(WorkerFutures);

    var discovery = try context.app.io.concurrent(discovery_worker, .{ context, loop });
    errdefer discovery.cancel(context.app.io);

    const sessions = switch (context.session_source) {
        .none => null,
        else => try context.app.io.concurrent(session_worker, .{ context, loop }),
    };

    owner.* = .{ .discovery = discovery, .sessions = sessions };
    if (sessions == null) {
        try loop.postEvent(.{
            .sessions = .{ .names = .empty },
        });
    }

    return .{
        .opaque_context = owner,
        .cancel_and_await_fn = cancel_and_await_workers,
    };
}

fn cancel_and_await_workers(owner_ptr: *anyopaque, io: std.Io) void {
    const owner: *WorkerFutures = @ptrCast(@alignCast(owner_ptr));
    if (owner.cleanup_complete) return;

    // Future.cancel is an idempotent cancellation request followed by await.
    owner.discovery.cancel(io);
    if (owner.sessions) |*future| future.cancel(io);

    owner.cleanup_complete = true;
}

fn discovery_worker(context: *LoadContext, loop: *vaxis.Loop(Ui.Event)) void {
    const result = discover(context, loop);
    loop.postEvent(.{ .discovery_result = result }) catch {};
}

fn discover(context: *LoadContext, loop: *vaxis.Loop(Ui.Event)) !void {
    var directory = try Dir.open_absolute(
        context.app.arena,
        context.app.io,
        context.app.home,
        context.root_path,
    );
    defer directory.close();

    var emitter: EmitContext = .{ .loop = loop };
    try Projects.discover_batches(context.app.arena, directory, &emitter);
}

fn session_worker(context: *LoadContext, loop: *vaxis.Loop(Ui.Event)) void {
    const sessions = session_names(context) catch Ui.SessionSet.empty;

    loop.postEvent(.{ .sessions = .{
        .names = sessions,
        .name_normalizer = if (context.session_source == .tmux) Tmux.session_name else null,
    } }) catch {};
}

fn session_names(context: *LoadContext) !Ui.SessionSet {
    return switch (context.session_source) {
        .none => unreachable,
        .tmux => try Tmux.list_sessions(context.app.arena, context.app.io),
        .herdr => |herdr| try herdr.list_sessions(context.root_path),
    };
}

test "direct selection prefers an exact name over fuzzy matches" {
    var collector: DirectCollector = .{ .query = "foo" };
    const batch: Projects.Batch = .{
        .root_path = "/projects/",
        .names = &.{ "foo-bar", "foobar", "foo" },
    };

    try collector.emit_batch(&batch);
    try std.testing.expectEqualStrings("foo", try collector.result());
}

test "direct selection accepts one fuzzy match" {
    var collector: DirectCollector = .{ .query = "sct" };
    const batch: Projects.Batch = .{
        .root_path = "/projects/",
        .names = &.{ "source-target", "other" },
    };

    try collector.emit_batch(&batch);
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
    const app: Self = .init(arena, io, &environ_map);

    const actual = try app.direct_path(root, "scout");
    const expected_root = try Dir.resolve_absolute_path(arena, io, null, root);
    const expected = try std.mem.concat(arena, u8, &.{ expected_root, "scout" });
    try std.testing.expectEqualStrings(expected, actual);
}

test "empty query skips direct selection" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    const app: Self = .init(arena_state.allocator(), io, &environ_map);

    try std.testing.expectError(error.NoMatch, app.direct_path("missing", ""));
}

test "direct selection rejects zero and multiple fuzzy matches" {
    var no_match: DirectCollector = .{ .query = "missing" };
    try no_match.emit_batch(&.{ .root_path = "/projects/", .names = &.{ "one", "two" } });
    try std.testing.expectError(error.NoMatch, no_match.result());

    var ambiguous: DirectCollector = .{ .query = "app" };
    try ambiguous.emit_batch(&.{
        .root_path = "/projects/",
        .names = &.{ "apple", "application" },
    });
    try std.testing.expectError(error.AmbiguousMatch, ambiguous.result());
}

test {
    _ = TerminalBackend;
    _ = Dir;
    _ = Herdr;
    _ = Projects;
    _ = Tmux;
    _ = Ui;
}
