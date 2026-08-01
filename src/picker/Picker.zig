//! Scout's in-process terminal picker.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ui = @import("Ui.zig");

pub const Event = Ui.Event;
pub const Loader = Ui.Loader;
pub const LoadWorkers = Ui.LoadWorkers;
pub const Selection = Ui.Selection;

arena: Allocator,
io: std.Io,
environ_map: *std.process.Environ.Map,

pub fn init(arena: Allocator, io: std.Io, environ_map: *std.process.Environ.Map) Self {
    return .{
        .arena = arena,
        .io = io,
        .environ_map = environ_map,
    };
}

/// Opens the picker while its entries load in the background.
pub fn pick(self: Self, loader: Loader) !?Selection {
    const ui: Ui = .init(self.arena, self.io, self.environ_map, loader);
    return ui.pick();
}

test {
    _ = Ui;
}
