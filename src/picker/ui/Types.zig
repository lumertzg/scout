//! Shared picker UI result types.

pub const Action = enum {
    ignore,
    redraw,
    accept,
    cancel,
};

pub const Selection = struct {
    root_path: []const u8,
    project_name: []const u8,
};
