//! Vaxis rendering for picker state.

const std = @import("std");
const assert = std.debug.assert;
const vaxis = @import("vaxis");

const Matcher = @import("Matcher.zig");
const Picker = @import("Picker.zig").Picker;
const Theme = @import("Theme.zig");

const active_marker = "• ";
const name_bytes_max = std.Io.Dir.max_name_bytes;
const status_buffer_bytes = 64;

/// Rendering history that does not belong to picker search state.
pub const Frame = struct {
    first_drawn_row: ?u16 = null,
};

pub fn draw(
    frame: *Frame,
    state: *Picker,
    vx: *vaxis.Vaxis,
    tty: *std.Io.Writer,
) !void {
    const window = vx.window();
    if (window.width == 0 or window.height == 0) return;

    const layout: Layout = .init(window.height);

    const visible_rows = layout.visibleRows();
    state.syncScroll(visible_rows);
    const view = state.renderView();
    const show_empty = visible_rows > 0 and view.matches.len == 0;
    const visible_count = view.visibleMatches(visible_rows).len;
    var list_rows = visible_count;
    if (show_empty) {
        list_rows = 1;
    }

    var list_first = layout.status_row;
    if (list_rows > 0) {
        list_first = layout.list_row_count - @as(u16, @intCast(list_rows));
    }
    const first_drawn_row = @min(list_first, layout.status_row);
    const clear_row = @min(frame.first_drawn_row orelse first_drawn_row, first_drawn_row);

    // Real default cells replace stale selection styles while restricting the
    // write set to rows used by the previous or current frame.
    window.child(.{
        .y_off = clear_row,
        .height = window.height - clear_row,
    }).fill(.{});
    frame.first_drawn_row = first_drawn_row;

    if (show_empty) {
        drawEmpty(view, window, layout.itemRow(0));
    } else {
        drawMatches(view, window, layout);
    }

    var status_buffer: [status_buffer_bytes]u8 = undefined;
    drawStatus(view, window, layout.status_row, &status_buffer);
    drawInput(view.query, window, layout.input_row);

    try vx.render(tty);
}

fn drawInput(query: []const u8, window: vaxis.Window, row: u16) void {
    const input = [_]vaxis.Segment{
        .{ .text = "> ", .style = Theme.accent },
        .{ .text = query },
    };
    const result = window.print(&input, .{
        .row_offset = row,
        .col_offset = 0,
        .wrap = .none,
    });

    if (query.len == 0) {
        _ = window.print(&.{
            .{ .text = "Filter projects", .style = Theme.muted },
        }, .{
            .row_offset = row,
            .col_offset = result.col,
            .wrap = .none,
        });
    }

    window.showCursor(@min(result.col, window.width - 1), row);
}

fn drawStatus(
    view: Picker.RenderView,
    window: vaxis.Window,
    row: u16,
    status_buffer: []u8,
) void {
    const pending = if (!view.discovery_complete) " discovering…" else "";
    const status = std.mem.print(
        status_buffer,
        "{d}/{d}{s}",
        .{ view.matches.len, view.entries.len, pending },
    ) catch unreachable;
    if (status.len <= window.width) {
        _ = window.print(&.{.{
            .text = status,
            .style = Theme.muted,
        }}, .{
            .row_offset = row,
            .col_offset = 0,
            .wrap = .none,
        });
    }
}

fn drawEmpty(view: Picker.RenderView, window: vaxis.Window, row: u16) void {
    const text = if (!view.discovery_complete and view.entries.len == 0)
        "  Loading projects…"
    else
        "  No matches";

    _ = window.print(&.{
        .{ .text = text, .style = Theme.muted },
    }, .{ .row_offset = row, .col_offset = 0, .wrap = .none });
}

fn drawMatches(view: Picker.RenderView, window: vaxis.Window, layout: Layout) void {
    for (view.visibleMatches(layout.visibleRows()), 0..) |match, visible_index| {
        const match_index = view.first_visible_index + visible_index;
        const is_selected = match_index == view.selected_index;
        drawItem(view, window, layout.itemRow(visible_index), match, is_selected);
    }
}

fn drawItem(
    view: Picker.RenderView,
    window: vaxis.Window,
    row: u16,
    match: Picker.RankedMatch,
    is_selected: bool,
) void {
    const entry = view.entry(match);
    const base_style = if (is_selected) Theme.selected else vaxis.Style{};
    const matched_style = if (is_selected) Theme.selected_match else Theme.matched;

    const gutter = [_]vaxis.Segment{.{
        .text = if (is_selected) "> " else "  ",
        .style = if (is_selected) Theme.selection_gutter else .{},
    }};

    var column = window.print(&gutter, .{
        .row_offset = row,
        .col_offset = 0,
        .wrap = .none,
    }).col;

    const active = entry.session_active;
    const marker_style = if (!active)
        base_style
    else if (is_selected)
        Theme.active_selected
    else
        Theme.active;

    column = printText(window, row, column, if (active) active_marker else "  ", marker_style);
    column = printWorkspaceIdentity(view, entry, window, row, column, base_style);

    if (view.query.len == 0 or view.query.len > name_bytes_max or !isAscii(view.query)) {
        column = printText(window, row, column, entry.name, base_style);
        return;
    }

    var positions_buffer: [name_bytes_max]usize = undefined;
    const positions = Matcher.positionsFolded(
        view.query,
        view.folded_query,
        entry.name,
        &positions_buffer,
    ) orelse unreachable;

    var text_index: usize = 0;
    var position_index: usize = 0;

    while (position_index < positions.len) {
        const match_start: usize = positions[position_index];
        column = printText(window, row, column, entry.name[text_index..match_start], base_style);

        var match_end = match_start + 1;
        position_index += 1;
        while (position_index < positions.len and
            positions[position_index] == match_end)
        {
            match_end += 1;
            position_index += 1;
        }

        column = printText(window, row, column, entry.name[match_start..match_end], matched_style);
        text_index = match_end;
    }

    column = printText(window, row, column, entry.name[text_index..], base_style);
}

fn printWorkspaceIdentity(
    view: Picker.RenderView,
    entry: Picker.Entry,
    window: vaxis.Window,
    row: u16,
    column: u16,
    style: vaxis.Style,
) u16 {
    const id = entry.workspace_id orelse return column;
    const duplicate = for (view.entries) |other| {
        const other_id = other.workspace_id orelse continue;
        if (!std.mem.eql(u8, id, other_id) and std.mem.eql(u8, entry.name, other.name)) {
            break true;
        }
    } else false;
    if (!duplicate) return column;
    var next_column = printText(window, row, column, "[", style);
    next_column = printText(window, row, next_column, id, style);
    return printText(window, row, next_column, "] ", style);
}

fn printText(
    window: vaxis.Window,
    row: u16,
    column: u16,
    text: []const u8,
    style: vaxis.Style,
) u16 {
    if (text.len == 0) return column;

    return window.print(&.{.{ .text = text, .style = style }}, .{
        .row_offset = row,
        .col_offset = column,
        .wrap = .none,
    }).col;
}

fn isAscii(text: []const u8) bool {
    for (text) |byte| {
        if (byte >= 0x80) return false;
    }

    return true;
}

/// Terminal rows reserved for the prompt, status, and project list.
const Layout = struct {
    input_row: u16,
    status_row: u16,
    list_row_count: u16,

    /// Computes a saturating layout for `height` terminal rows.
    fn init(height: u16) Layout {
        return .{
            .input_row = height -| 1,
            .status_row = height -| 2,
            // Keep one blank row between the project list and status.
            .list_row_count = height -| 3,
        };
    }

    fn visibleRows(self: Layout) usize {
        return self.list_row_count;
    }

    fn itemRow(self: Layout, visible_index: usize) u16 {
        assert(visible_index < self.visibleRows());
        // The list grows upward from the prompt so the selection stays near the
        // user's input on tall terminals.
        return self.list_row_count - 1 - @as(u16, @intCast(visible_index));
    }
};
