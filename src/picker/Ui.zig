//! Low-level Vaxis picker interface.

const Self = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const Projects = @import("../Projects.zig");
const Renderer = @import("Renderer.zig");
const Picker = @import("Picker.zig").Picker;
const NameNormalizer = @import("Picker.zig").NameNormalizer;

const tty_buffer_bytes = 1024;

pub const SessionSet = std.StringHashMapUnmanaged(void);
pub const Selection = Picker.Selection;

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
    pub fn cancelAndAwait(self: WorkerHandle, io: std.Io) void {
        self.cancel_and_await_fn(self.opaque_context, io);
    }
};

/// Connects application-specific loading work to the picker event loop.
pub const Loader = struct {
    /// Must remain valid until the returned worker handle has been cleaned up.
    context: *anyopaque,
    /// The event loop remains valid until `cancelAndAwait` returns.
    start_loading: *const fn (*anyopaque, *vaxis.Loop(Event)) anyerror!WorkerHandle,
};

const Runtime = struct {
    allocator: Allocator,
    io: std.Io,
    tty_buffer: [tty_buffer_bytes]u8,
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
        errdefer if (self.workers) |workers| workers.cancelAndAwait(ui.io);
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
        if (self.workers) |workers| workers.cancelAndAwait(self.io);
        self.* = undefined;
    }
};

const EventEffect = union(enum) {
    none,
    redraw,
    cancel,
    selection: Selection,
};

pub fn init(
    allocator: Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    loader: Loader,
) Self {
    return .{ .allocator = allocator, .io = io, .environ_map = environ_map, .loader = loader };
}

pub fn pick(self: Self) !?Selection {
    return self.pickWithQuery(null);
}

/// Runs the picker with an optional query already entered.
pub fn pickWithQuery(self: Self, initial_query: ?[]const u8) !?Selection {
    var runtime: Runtime = undefined;
    try runtime.init(self);
    defer runtime.deinit();

    var state = try Picker.init(self.allocator);
    defer state.deinit(self.allocator);

    if (initial_query) |query| try state.setQuery(self.allocator, query);

    var frame: Renderer.Frame = .{};
    var screen_ready = false;

    while (true) {
        try runtime.loop.pollEvent();
        var redraw = false;

        {
            try runtime.loop.queue.lock();
            defer runtime.loop.queue.unlock();

            while (runtime.loop.queue.drain()) |event| {
                switch (try self.handleEvent(&runtime, &state, &screen_ready, event)) {
                    .none => {},
                    .redraw => redraw = true,
                    .cancel => return null,
                    .selection => |selection| return selection,
                }
            }
        }

        state.applyPendingUpdates();
        if (screen_ready and redraw) {
            try Renderer.draw(&frame, &state, &runtime.vx, runtime.tty.writer());
        }
    }
}

fn handleEvent(
    self: Self,
    runtime: *Runtime,
    state: *Picker,
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
            return switch (try state.handleKey(self.allocator, key)) {
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
            return if (try state.appendBatch(self.allocator, batch))
                .redraw
            else
                .none;
        },
        .discovery_result => |result| {
            try result;
            state.finishDiscovery();
            return .redraw;
        },
        .sessions => |sessions| {
            return if (try state.setSessions(
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
    _ = @import("Picker.zig");
}
