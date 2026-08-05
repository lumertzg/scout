//! Scout application orchestration.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const Backend = @import("Backend.zig").Backend;
const Dir = @import("dir.zig");
const Git = @import("git.zig");
const Kitty = @import("Kitty.zig");
const Picker = @import("picker/Picker.zig");
const Projects = @import("Projects.zig");
const Tmux = @import("Tmux.zig");
const PickerLoop = vaxis.Loop(Picker.Event);

arena: Allocator,
io: std.Io,
/// Home directory used to expand a leading tilde in project roots.
home: ?[]const u8,
/// Whether Scout started inside a tmux client.
inside_tmux: bool,
environ_map: *std.process.Environ.Map,
picker: Picker,

const SessionSource = union(enum) {
    none,
    tmux_direct,
    tmux_control,
    kitty,
};

const LoadContext = struct {
    app: Self,
    root_path: []const u8,
    session_source: SessionSource,
    tmux_control: ?*Tmux = null,
    kitty: ?Kitty = null,
};

const WorkerFutures = struct {
    loading_future: std.Io.Future(void),
    cleanup_complete: bool = false,
};

const EmitContext = struct {
    app: Self,
    event_loop: *vaxis.Loop(Picker.Event),
    batches: *std.ArrayList(*Projects.Batch),

    /// Retains a discovered batch and posts it to the picker.
    pub fn emit_batch(self: *EmitContext, batch: *Projects.Batch) !void {
        try self.batches.append(self.app.arena, batch);
        try self.event_loop.postEvent(.{ .batch = batch });
    }
};

pub fn init(arena: Allocator, io: std.Io, environ_map: *std.process.Environ.Map) Self {
    return .{
        .arena = arena,
        .io = io,
        .home = environ_map.get("HOME"),
        .inside_tmux = environ_map.get("TMUX") != null,
        .environ_map = environ_map,
        .picker = .init(arena, io, environ_map),
    };
}

/// Lets the user choose a direct child of `root_path`.
///
/// The returned path belongs to `arena`. A null result means the user canceled.
pub fn pick_path(self: Self, root_path: []const u8) !?[]const u8 {
    var context: LoadContext = .{
        .app = self,
        .root_path = root_path,
        .session_source = .none,
    };

    const selection = try self.picker.pick(.{
        .context = &context,
        .start_loading = start_picker,
    }) orelse return null;

    return try std.mem.concat(self.arena, u8, &.{
        selection.root_path,
        selection.project_name,
    });
}

/// Lets the user choose a project and opens it with a terminal backend.
///
/// On success this may replace the Scout process and therefore not return.
pub fn open_project(self: Self, root_path: []const u8, backend: Backend) !void {
    const kitty: ?Kitty = if (backend == .kitty) try .init(self.arena, self.io, self.environ_map) else null;

    var context: LoadContext = .{
        .app = self,
        .root_path = root_path,
        .session_source = switch (backend) {
            .tmux => if (self.inside_tmux) .tmux_control else .tmux_direct,
            .kitty => .kitty,
            .path => .none,
        },
        .kitty = kitty,
    };

    const selection_result = self.picker.pick(.{
        .context = &context,
        .start_loading = start_picker,
    });

    // `close` kills and reaps the child on its own error path.
    defer if (context.tmux_control) |control| control.close() catch {};

    const selection = try selection_result orelse return;
    const project_path = try std.mem.concat(self.arena, u8, &.{
        selection.root_path,
        selection.project_name,
    });

    switch (backend) {
        .tmux => if (context.tmux_control) |control| {
            try control.switch_to_project(project_path);
        } else {
            try Tmux.replace_session(self.arena, self.io, project_path);
        },
        .kitty => try context.kitty.?.open_project(project_path),
        .path => unreachable,
    }
}

fn start_picker(opaque_context: *anyopaque, event_loop: *vaxis.Loop(Picker.Event)) !Picker.LoadWorkers {
    const context: *LoadContext = @ptrCast(@alignCast(opaque_context));
    const app = context.app;

    const worker_futures = try app.arena.create(WorkerFutures);
    const loading_future = try app.io.concurrent(loading_worker, .{ context, event_loop });

    worker_futures.* = .{
        .loading_future = loading_future,
    };

    return .{
        .opaque_context = worker_futures,
        .cancel_and_await_fn = cancel_and_await_workers,
    };
}

fn cancel_and_await_workers(opaque_context: *anyopaque, io: std.Io) void {
    const worker_futures: *WorkerFutures = @ptrCast(@alignCast(opaque_context));
    if (worker_futures.cleanup_complete) return;

    worker_futures.loading_future.cancel(io);
    worker_futures.cleanup_complete = true;
}

fn loading_worker(ctx: *LoadContext, loop: *PickerLoop) void {
    const app = ctx.app;
    var batches = std.ArrayList(*Projects.Batch).initCapacity(app.arena, Projects.BATCH_SIZE) catch |err| {
        loop.postEvent(.{ .discovery_result = err }) catch {};
        return;
    };

    const discovery_result = emit_batches(ctx, loop, &batches);
    loop.postEvent(.{ .discovery_result = discovery_result }) catch {};
    if (discovery_result) |_| {} else |_| return;

    var enrichment_group: std.Io.Group = .init;
    enrichment_group.concurrent(app.io, backend_enrichment_worker, .{ ctx, loop, batches.items }) catch |err| {
        loop.postEvent(.{ .backend_enrichment_result = err }) catch {};
        loop.postEvent(.{ .git_enrichment_result = err }) catch {};
        return;
    };
    enrichment_group.concurrent(app.io, git_enrichment_worker, .{ ctx, loop, batches.items }) catch |err| {
        loop.postEvent(.{ .git_enrichment_result = err }) catch {};
    };
    enrichment_group.await(app.io) catch {};
}

fn emit_batches(ctx: *LoadContext, loop: *PickerLoop, batches: *std.ArrayList(*Projects.Batch)) !void {
    const app = ctx.app;
    var directory = try Dir.open_absolute(app.arena, app.io, app.home, ctx.root_path);
    defer directory.close();

    var emit_context: EmitContext = .{
        .app = app,
        .event_loop = loop,
        .batches = batches,
    };

    try Projects.discover_batches(app.arena, directory, &emit_context);
}

fn backend_enrichment_worker(ctx: *LoadContext, loop: *PickerLoop, batches: []const *Projects.Batch) void {
    const result = enrich_backend_batches(ctx, loop, batches);
    loop.postEvent(.{ .backend_enrichment_result = result }) catch {};
}

fn git_enrichment_worker(ctx: *LoadContext, loop: *PickerLoop, batches: []const *Projects.Batch) void {
    const result = enrich_git_batches(ctx.app, loop, batches);
    loop.postEvent(.{ .git_enrichment_result = result }) catch {};
}

fn enrich_backend_batches(ctx: *LoadContext, loop: *PickerLoop, batches: []const *Projects.Batch) !void {
    const app = ctx.app;
    const sessions: Tmux.SessionSet = switch (ctx.session_source) {
        .none => .empty,
        .tmux_direct => try Tmux.list_sessions_direct(app.arena, app.io),
        .tmux_control => sessions: {
            const control = try Tmux.open(app.arena, app.io);
            ctx.tmux_control = control;
            break :sessions try control.list_sessions();
        },
        // Session marks are optional; selection must not fail when Kitty does.
        .kitty => ctx.kitty.?.list_sessions() catch .empty,
    };

    for (batches) |batch| {
        var fields = batch.projects.slice();
        var session_buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;
        for (fields.items(.name), fields.items(.session_active)) |project_name, *active| {
            active.* = switch (ctx.session_source) {
                .kitty => sessions.contains(project_name),
                else => sessions.contains(Tmux.session_name_buffered(project_name, &session_buffer)),
            };
        }
        batch.backend_enrichment_complete.store(true, .release);
        try loop.postEvent(.{ .batch_backend_enriched = batch });
    }
}

fn enrich_git_batches(app: Self, loop: *PickerLoop, batches: []const *Projects.Batch) !void {
    var git: Git = try .init();
    defer git.deinit();

    for (batches) |batch| try enrich_git_batch(app, loop, &git, batch);
}

fn enrich_git_batch(app: Self, loop: *PickerLoop, git: *Git, batch: *Projects.Batch) !void {
    var fields = batch.projects.slice();
    for (fields.items(.name), fields.items(.git_branch), fields.items(.git_state)) |project_name, *git_branch, *git_state| {
        if (try git.inspect(app.arena, batch.root_path, project_name)) |info| {
            git_branch.* = info.branch;
            git_state.* = info.state;
        }
    }

    batch.git_enrichment_complete.store(true, .release);
    try loop.postEvent(.{ .batch_git_enriched = batch });
}

test {
    _ = Dir;
    _ = Git;
    _ = Kitty;
    _ = Picker;
    _ = Projects;
    _ = Tmux;
}
