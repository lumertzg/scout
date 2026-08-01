//! Shared picker UI result types.

/// Effect of one key press on the picker loop.
pub const Action = enum {
    ignore,
    redraw,
    accept,
    cancel,
};

/// Location of a project chosen by the user.
pub const Selection = struct {
    /// Absolute parent path, including its trailing separator.
    root_path: []const u8,
    project_name: []const u8,
};
