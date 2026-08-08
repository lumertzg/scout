//! Low-level Vaxis picker interface.

const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const Projects = @import("../Projects.zig");
const Renderer = @import("Renderer.zig");
const State = @import("State.zig").State;
const NameNormalizer = @import("State.zig").NameNormalizer;

const TTY_BUFFER_BYTES = 1024;

pub const SessionSet = std.StringHashMapUnmanaged(void);
pub const Selection = State.Selection;

allocator: Allocator,
io: std.Io,
environ_map: *std.process.Environ.Map,
loader: Loader,

/// Input and immutable loading results consumed by the UI thread.
pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    batch: *const Projects.Batch,
    discovery_result: anyerror!void,
    sessions: SessionResult,
};

pub const SessionResult = struct {
    /// Ownership moves to picker state when this event is handled.
    names: SessionSet,
    name_normalizer: ?NameNormalizer = null,
};

/// Type-erased owner of all background tasks that can post UI events.
pub const WorkerHandle = struct {
    opaque_context: *anyopaque,
    cancel_and_await_fn: *const fn (*anyopaque, std.Io) void,

    /// Stops every task and waits until none can use the event loop again.
    /// Implementations must allow repeated calls.
    pub fn cancel_and_await(self: WorkerHandle, io: std.Io) void {
        self.cancel_and_await_fn(self.opaque_context, io);
    }
};

/// Connects application-specific loading work to the picker event loop.
pub const Loader = struct {
    /// Must remain valid until the returned worker handle has been cleaned up.
    context: *anyopaque,
    /// The event loop remains valid until `cancel_and_await` returns.
    start_loading: *const fn (*anyopaque, *vaxis.Loop(Event)) anyerror!WorkerHandle,
};

const Runtime = struct {
    allocator: Allocator,
    io: std.Io,
    tty_buffer: [TTY_BUFFER_BYTES]u8,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    loop: vaxis.Loop(Event),
    workers: ?WorkerHandle = null,
    resize_installed: bool = false,

    fn init(self: *Runtime, ui: Self) !void {
        self.allocator = ui.allocator;
        self.io = ui.io;
        self.workers = null;
        self.resize_installed = false;
        // Register worker cleanup first so later terminal cleanup runs before
        // waiting for canceled workers on every initialization error path.
        errdefer if (self.workers) |workers| workers.cancel_and_await(ui.io);
        self.tty = try .init(ui.io, &self.tty_buffer);
        errdefer self.tty.deinit();
        self.vx = try vaxis.init(ui.io, ui.allocator, ui.environ_map, .{});
        errdefer self.vx.deinit(ui.allocator, self.tty.writer());
        self.loop = .init(ui.io, &self.tty, &self.vx);
        try self.loop.start();
        errdefer self.loop.stop();
        try self.vx.enterAltScreen(self.tty.writer());

        self.workers = try ui.loader.start_loading(ui.loader.context, &self.loop);
        try self.vx.queryTerminal(self.tty.writer(), .fromMilliseconds(250));
        if (!self.vx.state.in_band_resize) {
            try self.loop.installResizeHandler();
            self.resize_installed = true;
        }
    }

    fn deinit(self: *Runtime) void {
        if (self.resize_installed) self.loop.uninstallResizeHandler();
        self.loop.stop();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        if (self.workers) |workers| workers.cancel_and_await(self.io);
    }
};

const EventEffect = union(enum) {
    none,
    redraw,
    cancel,
    selection: Selection,
};

pub fn init(allocator: Allocator, io: std.Io, environ_map: *std.process.Environ.Map, loader: Loader) Self {
    return .{ .allocator = allocator, .io = io, .environ_map = environ_map, .loader = loader };
}

pub fn pick(self: Self) !?Selection {
    var runtime: Runtime = undefined;
    try runtime.init(self);
    defer runtime.deinit();

    var state = try State.init(self.allocator);
    defer state.deinit(self.allocator);
    var frame: Renderer.FrameState = .{};
    var screen_ready = false;

    while (true) {
        try runtime.loop.pollEvent();
        var redraw = false;

        {
            try runtime.loop.queue.lock();
            defer runtime.loop.queue.unlock();

            while (runtime.loop.queue.drain()) |event| {
                switch (try self.handle_event(&runtime, &state, &screen_ready, event)) {
                    .none => {},
                    .redraw => redraw = true,
                    .cancel => return null,
                    .selection => |selection| return selection,
                }
            }
        }

        state.apply_pending_updates();
        if (screen_ready and redraw) {
            try Renderer.draw(&frame, &state, &runtime.vx, runtime.tty.writer());
        }
    }
}

fn handle_event(
    self: Self,
    runtime: *Runtime,
    state: *State,
    screen_ready: *bool,
    event: Event,
) !EventEffect {
    switch (event) {
        .winsize => |size| {
            try runtime.vx.resize(self.allocator, runtime.tty.writer(), size);
            screen_ready.* = true;
            return .redraw;
        },
        .key_press => |key| {
            return switch (try state.handle_key(self.allocator, key)) {
                .ignore => .none,
                .redraw => .redraw,
                .cancel => .cancel,
                .accept => if (state.selection()) |selection|
                    .{ .selection = selection }
                else
                    .none,
            };
        },
        .batch => |batch| {
            return if (try state.append_batch(self.allocator, batch))
                .redraw
            else
                .none;
        },
        .discovery_result => |result| {
            try result;
            state.finish_discovery();
            return .redraw;
        },
        .sessions => |sessions| {
            return if (try state.set_sessions(
                self.allocator,
                sessions.names,
                sessions.name_normalizer,
            ))
                .redraw
            else
                .none;
        },
    }
}

test {
    _ = @import("State.zig");
}
