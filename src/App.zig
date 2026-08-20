//! Scout application orchestration.

const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const TerminalBackend = @import("Backend.zig").TerminalBackend;
const Dir = @import("dir.zig");
const Herdr = @import("Herdr.zig");
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
    const selection = try self.pick(root_path, .none) orelse return null;

    return self.selection_path(selection);
}

pub fn open_project(self: Self, root_path: []const u8, backend: TerminalBackend) !void {
    const session_source: SessionSource = switch (backend) {
        .tmux => .tmux,
        .herdr => .{ .herdr = try .init(self.arena, self.io, self.environ_map) },
    };

    const selection = try self.pick(root_path, session_source) orelse return;
    const project_path = try self.selection_path(selection);

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

fn pick(self: Self, root_path: []const u8, session_source: SessionSource) !?Ui.Selection {
    var context: LoadContext = .{
        .app = self,
        .root_path = root_path,
        .session_source = session_source,
    };

    const picker: Ui = .init(self.arena, self.io, self.environ_map, .{
        .context = &context,
        .start_loading = start_workers,
    });

    return picker.pick();
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

test {
    _ = TerminalBackend;
    _ = Dir;
    _ = Herdr;
    _ = Projects;
    _ = Tmux;
    _ = Ui;
}
