//! Low-level Vaxis picker interface.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const Projects = @import("../Projects.zig");
const Renderer = @import("ui/Renderer.zig");
const ViewState = @import("ui/ViewState.zig").ViewState;

const EVENT_COUNT_PER_FRAME_MAX = 64;
const TTY_BUFFER_BYTES = 1024;

allocator: Allocator,
io: std.Io,
/// Environment used by Vaxis to detect terminal capabilities.
environ_map: *std.process.Environ.Map,
loader: Loader,

/// Type-erased owner of the background loading tasks.
pub const LoadWorkers = struct {
    opaque_context: *anyopaque,
    /// Cancels outstanding work and waits until it can no longer post events.
    /// The callback must tolerate more than one call.
    cancel_and_await_fn: *const fn (opaque_context: *anyopaque, io: std.Io) void,

    pub fn cancel_and_await(self: LoadWorkers, io: std.Io) void {
        self.cancel_and_await_fn(self.opaque_context, io);
    }
};

/// Type-erased callback that connects project loading to the picker loop.
pub const Loader = struct {
    context: *anyopaque,
    /// Starts workers that publish progress to `event_loop`.
    ///
    /// The returned handle owns those workers until `cancel_and_await` returns;
    /// neither the context nor event loop may be used after that point.
    start_loading: *const fn (
        opaque_context: *anyopaque,
        event_loop: *vaxis.Loop(Event),
    ) anyerror!LoadWorkers,
};

pub const Selection = @import("ui/Types.zig").Selection;

/// Input and background-work events consumed by the picker.
pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    batch: *Projects.Batch,
    /// Batch whose tmux fields are now published.
    batch_tmux_enriched: *Projects.Batch,
    /// Batch whose Git fields are now published.
    batch_git_enriched: *Projects.Batch,
    /// Final filesystem discovery result.
    discovery_result: anyerror!void,
    /// Final tmux and Git enrichment result.
    enrichment_result: anyerror!void,
};

pub fn init(allocator: Allocator, io: std.Io, environ_map: *std.process.Environ.Map, loader: Loader) Self {
    return .{
        .allocator = allocator,
        .io = io,
        .environ_map = environ_map,
        .loader = loader,
    };
}

/// Runs the terminal UI until the user selects a project or cancels.
pub fn pick(self: Self) !?Selection {
    var tty_buffer: [TTY_BUFFER_BYTES]u8 = undefined;
    var tty = try vaxis.Tty.init(self.io, &tty_buffer);
    defer tty.deinit();

    var vx = try vaxis.init(self.io, self.allocator, self.environ_map, .{});
    defer vx.deinit(self.allocator, tty.writer());
    try vx.enterAltScreen(tty.writer());

    var loop: vaxis.Loop(Event) = .init(self.io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try loop.installResizeHandler();
    defer loop.uninstallResizeHandler();

    const load_workers = try self.loader.start_loading(self.loader.context, &loop);
    defer load_workers.cancel_and_await(self.io);

    var view_state = try ViewState.init(self.allocator);
    defer view_state.deinit(self.allocator);

    var screen_ready = false;
    while (true) {
        try loop.pollEvent();

        var redraw = false;
        var event_count: usize = 0;

        while (event_count < EVENT_COUNT_PER_FRAME_MAX) : (event_count += 1) {
            const event = try loop.tryEvent() orelse break;
            switch (event) {
                .winsize => |winsize| {
                    try vx.resize(self.allocator, tty.writer(), winsize);
                    screen_ready = true;
                    redraw = true;
                },
                .key_press => |key| {
                    switch (try view_state.handle_key(self.allocator, key)) {
                        .ignore => {},
                        .redraw => redraw = true,
                        .accept => return view_state.selection(),
                        .cancel => return null,
                    }
                },
                .batch => |batch| {
                    try view_state.append_batch(self.allocator, batch);
                    redraw = true;
                },
                .batch_tmux_enriched => |batch| {
                    view_state.finish_batch_tmux_enrichment(batch);
                    redraw = true;
                },
                .batch_git_enriched => |batch| {
                    view_state.finish_batch_git_enrichment(batch);
                    redraw = true;
                },
                .discovery_result => |discovery_result| {
                    try discovery_result;
                    view_state.discovery_complete = true;
                    if (view_state.entry_count == 0) return null;
                    redraw = true;
                },
                .enrichment_result => |enrichment_result| {
                    try enrichment_result;
                    view_state.enrichment_complete = true;
                    redraw = true;
                },
            }
        }

        view_state.apply_pending_updates();

        if (screen_ready and redraw) {
            if (view_state.ready) |*ready| {
                try Renderer.draw(ready, view_state.discovery_complete, view_state.enrichment_complete, &vx, tty.writer());
            } else {
                try Renderer.draw_loading(view_state.loading_query.items, &vx, tty.writer());
            }
        }
    }
}

test {
    _ = @import("ui/tests.zig");
}
