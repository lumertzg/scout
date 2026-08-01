//! Scout application orchestration.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const Dir = @import("dir.zig");
const Git = @import("git.zig");
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
picker: Picker,

const SessionSource = union(enum) {
    none,
    direct,
    open_control,
};

const LoadContext = struct {
    app: Self,
    root_path: []const u8,
    session_source: SessionSource,
    tmux_control: ?*Tmux = null,
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

/// Lets the user choose a project and opens its tmux session.
///
/// On success this may replace the Scout process and therefore not return.
pub fn open_project_in_tmux(self: Self, root_path: []const u8) !void {
    var context: LoadContext = .{
        .app = self,
        .root_path = root_path,
        .session_source = if (self.inside_tmux) .open_control else .direct,
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

    if (context.tmux_control) |control| {
        try control.switch_to_project(project_path);
    } else {
        try Tmux.replace_session(self.arena, self.io, project_path);
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

    const enrichment_result = enrich_batches(ctx, loop, batches.items);
    loop.postEvent(.{ .enrichment_result = enrichment_result }) catch {};
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

fn enrich_batches(ctx: *LoadContext, loop: *PickerLoop, batches: []const *Projects.Batch) !void {
    const app = ctx.app;
    const sessions: Tmux.SessionSet = switch (ctx.session_source) {
        .none => .empty,
        .direct => try Tmux.list_sessions_direct(app.arena, app.io),
        .open_control => sessions: {
            const control = try Tmux.open(app.arena, app.io);
            ctx.tmux_control = control;
            break :sessions try control.list_sessions();
        },
    };

    for (batches) |batch| {
        var fields = batch.projects.slice();
        var session_buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;
        for (fields.items(.name), fields.items(.tmux_session_active)) |project_name, *active| {
            active.* = sessions.contains(Tmux.session_name_buffered(project_name, &session_buffer));
        }
        batch.tmux_enrichment_complete.store(true, .release);
        try loop.postEvent(.{ .batch_tmux_enriched = batch });
    }

    var git: Git = try .init();
    defer git.deinit();

    // The initial selection is active when any tmux session exists, so enrich
    // batches containing active projects before the remaining background work.
    for (batches) |batch| {
        if (batch_has_active_project(batch)) try enrich_git_batch(app, loop, &git, batch);
    }
    for (batches) |batch| {
        if (!batch_has_active_project(batch)) try enrich_git_batch(app, loop, &git, batch);
    }
}

fn batch_has_active_project(batch: *Projects.Batch) bool {
    for (batch.projects.slice().items(.tmux_session_active)) |active| {
        if (active) return true;
    }
    return false;
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
    _ = Picker;
    _ = Projects;
    _ = Tmux;
}
