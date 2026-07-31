//! Visual styles for the picker.

const vaxis = @import("vaxis");

const selected_background: vaxis.Color = .{ .index = 236 };

pub const accent: vaxis.Style = .{
    .fg = .{ .index = 6 },
    .bold = true,
};

pub const selection_gutter: vaxis.Style = .{
    .fg = .{ .index = 5 },
    .bold = true,
};

pub const active: vaxis.Style = .{
    .fg = .{ .index = 2 },
};

pub const active_selected: vaxis.Style = .{
    .fg = .{ .index = 2 },
    .bg = selected_background,
};

pub const selected: vaxis.Style = .{
    .bg = selected_background,
};

pub const matched: vaxis.Style = .{
    .fg = .{ .index = 108 },
    .bg = .{ .index = 0 },
};

pub const selected_match: vaxis.Style = .{
    .fg = .{ .index = 151 },
    .bg = selected_background,
};

pub const muted: vaxis.Style = .{
    .dim = true,
};
