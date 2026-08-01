//! Vaxis rendering for picker state.

const std = @import("std");
const assert = std.debug.assert;
const vaxis = @import("vaxis");

const Matcher = @import("../Matcher.zig");
const State = @import("State.zig").State;
const Theme = @import("../Theme.zig");

const ACTIVE_MARKER = "• ";
const STATUS_BUFFER_BYTES = 64;

pub fn draw(
    state: *State,
    discovery_complete: bool,
    enrichment_complete: bool,
    vx: *vaxis.Vaxis,
    tty: *std.Io.Writer,
) !void {
    const window = vx.window();
    if (window.width == 0 or window.height == 0) return;

    const layout: Layout = .init(window.height);

    state.sync_scroll(layout.visible_rows());
    const visible_count = @min(layout.visible_rows(), state.match_count - state.first_visible_index);
    var list_rows = visible_count;
    if (state.match_count == 0 and layout.visible_rows() > 0) {
        list_rows = 1;
    }

    var list_first = layout.status_row;
    if (list_rows > 0) {
        list_first = layout.list_row_end - @as(u16, @intCast(list_rows));
    }
    const first_drawn_row = @min(list_first, layout.status_row);
    const clear_row = @min(state.first_drawn_row orelse first_drawn_row, first_drawn_row);

    // Real default cells replace stale selection styles while restricting the
    // write set to rows used by the previous or current frame.
    window.child(.{
        .y_off = clear_row,
        .height = window.height - clear_row,
    }).fill(.{});
    state.first_drawn_row = first_drawn_row;

    if (state.match_count == 0 and layout.visible_rows() > 0) {
        draw_empty(window, layout.item_row(0));
    } else {
        draw_matches(state, window, layout);
    }

    var status_buffer: [STATUS_BUFFER_BYTES]u8 = undefined;
    draw_status(state, discovery_complete, enrichment_complete, window, layout.status_row, &status_buffer);
    draw_input(state.query.items, window, layout.input_row);

    try vx.render(tty);
}

pub fn draw_loading(query: []const u8, vx: *vaxis.Vaxis, tty: *std.Io.Writer) !void {
    const window = vx.window();
    if (window.width == 0 or window.height == 0) return;

    const layout: Layout = .init(window.height);
    window.child(.{
        .y_off = layout.status_row,
        .height = window.height - layout.status_row,
    }).fill(.{});

    _ = window.print(&.{.{
        .text = "Loading projects…",
        .style = Theme.muted,
    }}, .{
        .row_offset = layout.status_row,
        .col_offset = 0,
        .wrap = .none,
    });
    draw_input(query, window, layout.input_row);

    try vx.render(tty);
}

fn draw_input(query: []const u8, window: vaxis.Window, row: u16) void {
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

fn draw_status(
    state: *const State,
    discovery_complete: bool,
    enrichment_complete: bool,
    window: vaxis.Window,
    row: u16,
    status_buffer: []u8,
) void {
    const pending = if (!discovery_complete) " discovering…" else if (!enrichment_complete) " enriching…" else "";
    const status = std.fmt.bufPrint(status_buffer, "{d}/{d}{s}", .{ state.match_count, state.entries.len(), pending }) catch unreachable;
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

fn draw_empty(window: vaxis.Window, row: u16) void {
    _ = window.print(&.{
        .{ .text = "  No matches", .style = Theme.muted },
    }, .{ .row_offset = row, .col_offset = 0, .wrap = .none });
}

fn draw_matches(state: *State, window: vaxis.Window, layout: Layout) void {
    const visible_count = @min(layout.visible_rows(), state.match_count - state.first_visible_index);

    for (0..visible_count) |visible_index| {
        const match_index = state.first_visible_index + visible_index;
        const match = state.matches.items[match_index];
        const is_selected = match_index == state.selected_index;
        draw_item(state, window, layout.item_row(visible_index), match, is_selected);
    }
}

fn draw_item(state: *State, window: vaxis.Window, row: u16, match: State.RankedMatch, is_selected: bool) void {
    const project_name = state.entries.entry_name(match.entry_index);
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

    const active = state.entries.entry_is_tmux_session_active(match.entry_index);
    const marker_style = if (!active) base_style else if (is_selected) Theme.active_selected else Theme.active;

    column = print_text(window, row, column, if (active) ACTIVE_MARKER else "  ", marker_style);

    if (state.query.items.len == 0 or !is_ascii(state.query.items)) {
        column = print_text(window, row, column, project_name, base_style);
        draw_git(state, window, row, column, match.entry_index, is_selected, base_style);
        return;
    }

    var positions_buffer: [std.Io.Dir.max_name_bytes]u16 = undefined;
    const positions = Matcher.positions_folded(
        state.query.items,
        state.folded_query.items,
        project_name,
        &positions_buffer,
    ) orelse unreachable;

    var text_index: usize = 0;
    var position_index: usize = 0;

    while (position_index < positions.len) {
        const match_start: usize = positions[position_index];
        column = print_text(window, row, column, project_name[text_index..match_start], base_style);

        var match_end = match_start + 1;
        position_index += 1;
        while (position_index < positions.len and @as(usize, positions[position_index]) == match_end) {
            match_end += 1;
            position_index += 1;
        }

        column = print_text(window, row, column, project_name[match_start..match_end], matched_style);
        text_index = match_end;
    }

    column = print_text(window, row, column, project_name[text_index..], base_style);
    draw_git(state, window, row, column, match.entry_index, is_selected, base_style);
}

fn draw_git(
    state: *const State,
    window: vaxis.Window,
    row: u16,
    initial_column: u16,
    entry_index: usize,
    is_selected: bool,
    base_style: vaxis.Style,
) void {
    if (!should_draw_git_metadata(is_selected)) return;

    const branch = state.entries.entry_git_branch(entry_index);
    const git_state = state.entries.entry_git_state(entry_index);
    if (branch == null and git_state.is_empty()) return;

    const branch_style = Theme.git_branch_selected;
    const status_style = Theme.git_status_selected;
    var column = print_text(window, row, initial_column, "  ", base_style);

    if (branch) |name| {
        column = print_text(window, row, column, name, branch_style);
    }

    if (git_state.is_empty()) return;
    if (branch != null) column = print_text(window, row, column, " ", base_style);

    column = print_text(window, row, column, "[", status_style);
    if (git_state.conflicted) column = print_text(window, row, column, "=", status_style);
    if (git_state.stashed) column = print_text(window, row, column, "$", status_style);
    if (git_state.deleted) column = print_text(window, row, column, "✘", status_style);
    if (git_state.renamed) column = print_text(window, row, column, "»", status_style);
    if (git_state.modified) column = print_text(window, row, column, "!", status_style);
    if (git_state.staged) column = print_text(window, row, column, "+", status_style);
    if (git_state.untracked) column = print_text(window, row, column, "?", status_style);
    if (git_state.ahead and git_state.behind) {
        column = print_text(window, row, column, "⇕", status_style);
    } else if (git_state.ahead) {
        column = print_text(window, row, column, "⇡", status_style);
    } else if (git_state.behind) {
        column = print_text(window, row, column, "⇣", status_style);
    }
    _ = print_text(window, row, column, "]", status_style);
}

pub fn should_draw_git_metadata(is_selected: bool) bool {
    return is_selected;
}

fn print_text(window: vaxis.Window, row: u16, column: u16, text: []const u8, style: vaxis.Style) u16 {
    if (text.len == 0) return column;

    return window.print(&.{.{ .text = text, .style = style }}, .{
        .row_offset = row,
        .col_offset = column,
        .wrap = .none,
    }).col;
}

fn is_ascii(text: []const u8) bool {
    for (text) |byte| {
        if (byte >= 0x80) return false;
    }

    return true;
}

pub const Layout = struct {
    input_row: u16,
    status_row: u16,
    list_row_end: u16,

    pub fn init(height: u16) Layout {
        return .{
            .input_row = height -| 1,
            .status_row = height -| 2,
            .list_row_end = height -| 3,
        };
    }

    pub fn visible_rows(self: Layout) usize {
        return self.list_row_end;
    }

    pub fn item_row(self: Layout, visible_index: usize) u16 {
        assert(visible_index < self.visible_rows());
        return self.list_row_end - 1 - @as(u16, @intCast(visible_index));
    }
};
