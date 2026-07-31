//! Low-level Vaxis picker interface.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const vaxis = @import("vaxis");

const Entries = @import("Entries.zig");
const Matcher = @import("Matcher.zig");
const Projects = @import("../Projects.zig");
const Theme = @import("Theme.zig");
const Tmux = @import("../Tmux.zig");

const ACTIVE_MARKER = "• ";

pub const Loaded = struct {
    projects: Projects,
    sessions: ?Tmux.SessionSet = null,
};

pub const Loader = struct {
    context: *anyopaque,
    load: *const fn (context: *anyopaque) anyerror!Loaded,
};

pub const Selection = struct {
    projects: Projects,
    project_index: usize,
};

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    loaded: anyerror!Loaded,
};

// Bound event draining so pasted input amortizes rendering without allowing a
// continuously full queue to starve the next frame.
const EVENT_COUNT_PER_FRAME_MAX = 64;
const QUERY_BYTES_EXPECTED = 64;
const PROJECT_COUNT_MAX = Projects.PROJECT_COUNT_PICKER_MAX;
const PROJECT_NAME_BYTES_MAX = std.Io.Dir.max_name_bytes;
const MATCH_POSITION_BYTES_MAX = PROJECT_COUNT_MAX * PROJECT_NAME_BYTES_MAX * @sizeOf(u16);
const STATUS_BUFFER_BYTES = 32;
const TTY_BUFFER_BYTES = 1024;

comptime {
    assert(PROJECT_COUNT_MAX <= std.math.maxInt(u16));
    assert(PROJECT_NAME_BYTES_MAX <= std.math.maxInt(u16));
}

allocator: Allocator,
io: std.Io,
environ_map: *std.process.Environ.Map,
loader: Loader,

pub fn init(allocator: Allocator, io: std.Io, environ_map: *std.process.Environ.Map, loader: Loader) Self {
    return .{
        .allocator = allocator,
        .io = io,
        .environ_map = environ_map,
        .loader = loader,
    };
}

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

    var load_future = try self.io.concurrent(load_and_notify, .{ self.loader, &loop });
    defer load_future.cancel(self.io);

    var view_state = try ViewState.init(self.allocator);
    defer view_state.deinit(self.allocator);

    var screen_ready = false;
    // The user bounds the loop lifetime; each turn drains at most one batch.
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
                .loaded => |loaded_result| {
                    load_future.await(self.io);
                    if (!try view_state.finish_loading(self.allocator, try loaded_result)) return null;
                    redraw = true;
                },
            }
        }

        view_state.apply_pending_filter();
        if (screen_ready and redraw) {
            if (view_state.ready) |*ready| {
                try draw(ready, &vx, tty.writer());
            } else {
                try draw_loading(view_state.loading_query.items, &vx, tty.writer());
            }
        }
    }
}

fn load_and_notify(loader: Loader, loop: *vaxis.Loop(Event)) void {
    const result = loader.load(loader.context);
    loop.postEvent(.{ .loaded = result }) catch {};
}

const Action = enum {
    ignore,
    redraw,
    accept,
    cancel,
};

fn handle_loading_key(query: *std.ArrayList(u8), allocator: Allocator, key: vaxis.Key) !Action {
    if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
        return .cancel;
    }

    if (key.matches(vaxis.Key.backspace, .{})) {
        if (query.items.len == 0) return .ignore;
        remove_last_codepoint(query);
        return .redraw;
    }

    const text = key.text orelse return .ignore;
    if (!accepts_text(key.mods, text)) return .ignore;
    assert(query.items.len <= PROJECT_NAME_BYTES_MAX);
    if (text.len > PROJECT_NAME_BYTES_MAX - query.items.len) return .ignore;

    try query.appendSlice(allocator, text);
    return .redraw;
}

const PendingFilter = enum {
    none,
    narrow,
    refresh,
};

const State = struct {
    const RankedMatch = struct {
        score: i32,
        entry_index: u16,
        match_span: u16,
        item_bytes: u16,
    };

    entries: Entries.List,

    query: std.ArrayList(u8) = .empty,
    folded_query: std.ArrayList(u8) = .empty,

    matches: []RankedMatch,
    positions: []u16,
    positions_per_project: usize,

    match_count: usize = 0,
    selected_index: usize = 0,
    first_visible_index: usize = 0,

    first_drawn_row: ?u16 = null,
    pending_filter: PendingFilter = .none,

    fn init(allocator: Allocator, entries: Entries.List) !State {
        const entry_count = entries.len();
        if (entry_count > PROJECT_COUNT_MAX) return error.TooManyProjects;

        const matches = try allocator.alloc(RankedMatch, entry_count);
        errdefer allocator.free(matches);

        var project_name_bytes_max: usize = 0;
        for (0..entry_count) |entry_index| {
            const project_name = entries.name(entry_index);
            project_name_bytes_max = @max(project_name_bytes_max, project_name.len);
        }
        if (project_name_bytes_max > PROJECT_NAME_BYTES_MAX) return error.ProjectNameTooLong;
        assert(entries.active_count <= entry_count);

        const position_count = try std.math.mul(usize, entry_count, project_name_bytes_max);
        assert(position_count * @sizeOf(u16) <= MATCH_POSITION_BYTES_MAX);
        const positions = try allocator.alloc(u16, position_count);
        errdefer allocator.free(positions);

        var query = try std.ArrayList(u8).initCapacity(allocator, @min(project_name_bytes_max, QUERY_BYTES_EXPECTED));
        errdefer query.deinit(allocator);

        const folded_query = try std.ArrayList(u8).initCapacity(allocator, @min(project_name_bytes_max, QUERY_BYTES_EXPECTED));

        var state: State = .{
            .entries = entries,
            .query = query,
            .folded_query = folded_query,
            .matches = matches,
            .positions = positions,
            .positions_per_project = project_name_bytes_max,
        };

        state.refresh_matches();

        return state;
    }

    fn deinit(self: *State, allocator: Allocator) void {
        self.query.deinit(allocator);
        self.folded_query.deinit(allocator);
        allocator.free(self.matches);
        allocator.free(self.positions);
    }

    fn handle_key(self: *State, allocator: Allocator, key: vaxis.Key) !Action {
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
            return .cancel;
        }

        if (key.matches(vaxis.Key.enter, .{})) {
            self.apply_pending_filter();
            return .accept;
        }

        if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
            self.apply_pending_filter();
            return if (self.move_up()) .redraw else .ignore;
        }

        if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
            self.apply_pending_filter();
            return if (self.move_down()) .redraw else .ignore;
        }

        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.query.items.len == 0) return .ignore;
            remove_last_codepoint(&self.query);
            remove_last_codepoint(&self.folded_query);
            self.pending_filter = .refresh;
            return .redraw;
        }

        const text = key.text orelse return .ignore;

        if (!accepts_text(key.mods, text)) return .ignore;
        assert(self.query.items.len <= self.positions_per_project);
        if (text.len > self.positions_per_project - self.query.items.len) return .ignore;

        try self.append_query(allocator, text);
        if (self.pending_filter == .none) self.pending_filter = .narrow;

        return .redraw;
    }

    fn append_query(self: *State, allocator: Allocator, text: []const u8) !void {
        assert(self.query.items.len == self.folded_query.items.len);
        assert(text.len <= self.positions_per_project - self.query.items.len);
        const folded_len = self.folded_query.items.len;
        errdefer self.folded_query.items.len = folded_len;

        for (text) |byte| {
            try self.folded_query.append(allocator, std.ascii.toLower(byte));
        }

        try self.query.appendSlice(allocator, text);
        assert(self.query.items.len == self.folded_query.items.len);
    }

    fn refresh_matches(self: *State) void {
        assert(self.query.items.len == self.folded_query.items.len);
        assert(self.matches.len == self.entries.len());
        if (self.query.items.len == 0) {
            for (self.matches, 0..) |*match, entry_index| {
                match.* = .{
                    .entry_index = @intCast(entry_index),
                    .score = 0,
                    .match_span = 0,
                    .item_bytes = @intCast(self.entries.name(entry_index).len),
                };
            }

            self.match_count = self.entries.len();
            self.reset_selection();

            return;
        }

        self.match_count = 0;
        const query = self.query.items;
        const folded_query = self.folded_query.items;
        for (0..self.entries.len()) |entry_index| {
            const project_name = self.entries.name(entry_index);
            const entry_index_u16: u16 = @intCast(entry_index);
            const match_positions = self.project_positions(entry_index_u16);
            const result = Matcher.rank_folded_positions(query, folded_query, project_name, match_positions) orelse continue;

            self.matches[self.match_count] = .{
                .entry_index = entry_index_u16,
                .score = result.score,
                .match_span = @intCast(result.end - result.start),
                .item_bytes = @intCast(project_name.len),
            };

            self.match_count += 1;
        }

        assert(self.match_count <= self.matches.len);
        self.sort_matches();
        self.reset_selection();
    }

    fn narrow_matches(self: *State) void {
        assert(self.query.items.len == self.folded_query.items.len);
        assert(self.match_count <= self.matches.len);
        var narrowed_count: usize = 0;
        const query = self.query.items;
        const folded_query = self.folded_query.items;
        for (self.matches[0..self.match_count]) |match| {
            const project_name = self.entries.name(match.entry_index);
            const match_positions = self.project_positions(match.entry_index);
            const result = Matcher.rank_folded_positions(query, folded_query, project_name, match_positions) orelse continue;

            self.matches[narrowed_count] = .{
                .entry_index = match.entry_index,
                .score = result.score,
                .match_span = @intCast(result.end - result.start),
                .item_bytes = match.item_bytes,
            };

            narrowed_count += 1;
        }

        assert(narrowed_count <= self.match_count);
        self.match_count = narrowed_count;
        self.sort_matches();
        self.reset_selection();
    }

    fn apply_pending_filter(self: *State) void {
        const pending_filter = self.pending_filter;
        self.pending_filter = .none;

        switch (pending_filter) {
            .none => {},
            .narrow => self.narrow_matches(),
            .refresh => self.refresh_matches(),
        }
        assert(self.query.items.len == self.folded_query.items.len);
    }

    fn project_positions(self: State, entry_index: u16) []u16 {
        assert(entry_index < self.entries.len());
        const start = @as(usize, entry_index) * self.positions_per_project;
        assert(start + self.positions_per_project <= self.positions.len);
        return self.positions[start..][0..self.positions_per_project];
    }

    fn sort_matches(self: *State) void {
        assert(self.match_count <= self.matches.len);
        std.mem.sortUnstable(RankedMatch, self.matches[0..self.match_count], {}, less_than);
    }

    fn less_than(_: void, left: RankedMatch, right: RankedMatch) bool {
        if (left.score != right.score) return left.score > right.score;
        if (left.match_span != right.match_span) return left.match_span < right.match_span;
        if (left.item_bytes != right.item_bytes) return left.item_bytes < right.item_bytes;
        return left.entry_index < right.entry_index;
    }

    fn reset_selection(self: *State) void {
        self.selected_index = 0;
        self.first_visible_index = 0;
    }

    fn move_up(self: *State) bool {
        if (self.match_count > 0) assert(self.selected_index < self.match_count);
        if (self.selected_index + 1 >= self.match_count) return false;
        self.selected_index += 1;
        return true;
    }

    fn move_down(self: *State) bool {
        if (self.match_count > 0) assert(self.selected_index < self.match_count);
        if (self.selected_index == 0) return false;
        self.selected_index -= 1;
        return true;
    }

    fn selected_item(self: State) ?[]const u8 {
        if (self.match_count == 0) return null;
        assert(self.selected_index < self.match_count);
        return self.entries.name(self.matches[self.selected_index].entry_index);
    }

    fn selected_project_index(self: State) ?usize {
        if (self.match_count == 0) return null;
        assert(self.selected_index < self.match_count);
        return self.entries.project_index(self.matches[self.selected_index].entry_index);
    }

    fn sync_scroll(self: *State, visible_rows: usize) void {
        if (visible_rows == 0 or self.match_count == 0) return;
        assert(self.selected_index < self.match_count);

        if (self.selected_index < self.first_visible_index) {
            self.first_visible_index = self.selected_index;
        } else if (self.selected_index >= self.first_visible_index + visible_rows) {
            self.first_visible_index = self.selected_index - visible_rows + 1;
        }
    }
};

const ViewState = struct {
    loading_query: std.ArrayList(u8),
    ready: ?State = null,

    fn init(allocator: Allocator) !ViewState {
        return .{
            .loading_query = try std.ArrayList(u8).initCapacity(allocator, QUERY_BYTES_EXPECTED),
        };
    }

    fn deinit(self: *ViewState, allocator: Allocator) void {
        self.loading_query.deinit(allocator);
        if (self.ready) |*ready| ready.deinit(allocator);
    }

    fn handle_key(self: *ViewState, allocator: Allocator, key: vaxis.Key) !Action {
        if (self.ready) |*ready| return ready.handle_key(allocator, key);
        return handle_loading_key(&self.loading_query, allocator, key);
    }

    fn finish_loading(self: *ViewState, allocator: Allocator, loaded: Loaded) !bool {
        assert(self.ready == null);
        var entries = Entries.from_projects(loaded.projects);
        if (loaded.sessions) |sessions| {
            entries = try Entries.with_active_sessions(allocator, loaded.projects, sessions);
        }
        if (entries.len() == 0) return false;

        self.ready = try State.init(allocator, entries);
        const ready = &self.ready.?;
        const query_len = valid_prefix_len(self.loading_query.items, ready.positions_per_project);
        if (query_len > 0) {
            try ready.append_query(allocator, self.loading_query.items[0..query_len]);
            ready.refresh_matches();
        }
        return true;
    }

    fn selection(self: ViewState) ?Selection {
        const ready = self.ready orelse return null;
        const project_index = ready.selected_project_index() orelse return null;
        return .{
            .projects = ready.entries.projects,
            .project_index = project_index,
        };
    }

    fn apply_pending_filter(self: *ViewState) void {
        if (self.ready) |*ready| ready.apply_pending_filter();
    }
};

fn draw(state: *State, vx: *vaxis.Vaxis, tty: *std.Io.Writer) !void {
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
    draw_status(state, window, layout.status_row, &status_buffer);
    draw_input(state.query.items, window, layout.input_row);

    try vx.render(tty);
}

fn draw_loading(query: []const u8, vx: *vaxis.Vaxis, tty: *std.Io.Writer) !void {
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

fn draw_status(state: *const State, window: vaxis.Window, row: u16, status_buffer: []u8) void {
    const status = std.fmt.bufPrint(status_buffer, "{d}/{d}", .{ state.match_count, state.entries.len() }) catch unreachable;
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
        const match = state.matches[match_index];
        const is_selected = match_index == state.selected_index;
        draw_item(state, window, layout.item_row(visible_index), match, is_selected);
    }
}

fn draw_item(state: *State, window: vaxis.Window, row: u16, match: State.RankedMatch, is_selected: bool) void {
    const project_name = state.entries.name(match.entry_index);
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

    const active = state.entries.is_active(match.entry_index);
    const marker_style = if (!active) base_style else if (is_selected) Theme.active_selected else Theme.active;
    column = print_text(window, row, column, if (active) ACTIVE_MARKER else "  ", marker_style);

    if (state.query.items.len == 0 or !is_ascii(state.query.items)) {
        _ = print_text(window, row, column, project_name, base_style);
        return;
    }

    const positions = state.project_positions(match.entry_index)[0..state.query.items.len];

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

    _ = print_text(window, row, column, project_name[text_index..], base_style);
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

const Layout = struct {
    input_row: u16,
    status_row: u16,
    list_row_end: u16,

    fn init(height: u16) Layout {
        return .{
            .input_row = height -| 1,
            .status_row = height -| 2,
            .list_row_end = height -| 3,
        };
    }

    fn visible_rows(self: Layout) usize {
        return self.list_row_end;
    }

    fn item_row(self: Layout, visible_index: usize) u16 {
        assert(visible_index < self.visible_rows());
        return self.list_row_end - 1 - @as(u16, @intCast(visible_index));
    }
};

fn accepts_text(mods: vaxis.Key.Modifiers, text: []const u8) bool {
    if (mods.ctrl or mods.alt or mods.super or mods.hyper or mods.meta) return false;
    return text.len > 0 and text[0] >= ' ' and text[0] != 0x7f;
}

fn remove_last_codepoint(query: *std.ArrayList(u8)) void {
    if (query.items.len == 0) return;

    var new_len = query.items.len - 1;

    while (new_len > 0 and query.items[new_len] & 0xc0 == 0x80) {
        new_len -= 1;
    }

    query.items.len = new_len;
}

fn valid_prefix_len(text: []const u8, byte_limit: usize) usize {
    var prefix_len = @min(text.len, byte_limit);
    if (prefix_len == text.len) return prefix_len;

    while (prefix_len > 0 and text[prefix_len] & 0xc0 == 0x80) {
        prefix_len -= 1;
    }
    return prefix_len;
}

test "loading input preserves typed text and backspace" {
    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(std.testing.allocator);

    const typed = try handle_loading_key(&query, std.testing.allocator, .{
        .codepoint = 'é',
        .text = "café",
    });
    try std.testing.expectEqual(Action.redraw, typed);
    try std.testing.expectEqualStrings("café", query.items);

    const erased = try handle_loading_key(&query, std.testing.allocator, .{
        .codepoint = vaxis.Key.backspace,
    });
    try std.testing.expectEqual(Action.redraw, erased);
    try std.testing.expectEqualStrings("caf", query.items);
}

test "loading query truncates only at a UTF-8 boundary" {
    try std.testing.expectEqual(@as(usize, 2), valid_prefix_len("abécd", 3));
    try std.testing.expectEqual(@as(usize, 4), valid_prefix_len("abécd", 4));
    try std.testing.expectEqual(@as(usize, 6), valid_prefix_len("abécd", 10));
}

test "loading query is applied when projects arrive" {
    const project_names = [_][]const u8{ "scout", "other", "source" };
    const entries = try test_entries(std.testing.allocator, &project_names, 0);
    defer deinit_test_entries(entries);

    var view_state = try ViewState.init(std.testing.allocator);
    defer view_state.deinit(std.testing.allocator);

    _ = try view_state.handle_key(std.testing.allocator, .{ .codepoint = 's', .text = "s" });
    _ = try view_state.handle_key(std.testing.allocator, .{ .codepoint = 'o', .text = "o" });
    try std.testing.expect(try view_state.finish_loading(std.testing.allocator, .{
        .projects = entries.projects,
    }));

    const ready = &view_state.ready.?;
    try std.testing.expectEqualStrings("so", ready.query.items);
    try std.testing.expectEqual(@as(usize, 2), ready.match_count);
    try std.testing.expectEqualStrings("source", ready.selected_item().?);
}

test "state filters and selects matches" {
    const items = [_][]const u8{ "scout", "other", "source" };
    const entries = try test_entries(std.testing.allocator, &items, 0);
    defer deinit_test_entries(entries);
    var state = try State.init(std.testing.allocator, entries);
    defer state.deinit(std.testing.allocator);

    try state.append_query(std.testing.allocator, "so");
    state.refresh_matches();

    try std.testing.expectEqual(@as(usize, 2), state.match_count);
    try std.testing.expectEqualStrings("source", state.selected_item().?);
    var selected_positions = state.project_positions(state.matches[state.selected_index].entry_index)[0..2];
    try std.testing.expectEqualSlices(u16, &.{ 0, 1 }, selected_positions);
    try std.testing.expect(state.move_up());
    try std.testing.expectEqualStrings("scout", state.selected_item().?);
    selected_positions = state.project_positions(state.matches[state.selected_index].entry_index)[0..2];
    try std.testing.expectEqualSlices(u16, &.{ 0, 2 }, selected_positions);
}

test "growing a query narrows only existing matches" {
    const items = [_][]const u8{ "scout", "other", "source", "rust" };
    const entries = try test_entries(std.testing.allocator, &items, 0);
    defer deinit_test_entries(entries);
    var state = try State.init(std.testing.allocator, entries);
    defer state.deinit(std.testing.allocator);

    try state.append_query(std.testing.allocator, "s");
    state.narrow_matches();
    try std.testing.expectEqual(@as(usize, 3), state.match_count);

    try state.append_query(std.testing.allocator, "o");
    state.narrow_matches();
    try std.testing.expectEqual(@as(usize, 2), state.match_count);
    try std.testing.expectEqualStrings("source", state.entries.name(state.matches[0].entry_index));
    try std.testing.expectEqualStrings("scout", state.entries.name(state.matches[1].entry_index));

    remove_last_codepoint(&state.query);
    remove_last_codepoint(&state.folded_query);
    state.refresh_matches();
    try std.testing.expectEqual(@as(usize, 3), state.match_count);
    try std.testing.expectEqualStrings("rust", state.entries.name(state.matches[2].entry_index));
}

test "batched query growth filters once at flush" {
    const items = [_][]const u8{ "scout", "other", "source", "rust" };
    const entries = try test_entries(std.testing.allocator, &items, 0);
    defer deinit_test_entries(entries);
    var state = try State.init(std.testing.allocator, entries);
    defer state.deinit(std.testing.allocator);

    try state.append_query(std.testing.allocator, "s");
    state.pending_filter = .narrow;
    try state.append_query(std.testing.allocator, "o");

    try std.testing.expectEqual(@as(usize, items.len), state.match_count);
    state.apply_pending_filter();
    try std.testing.expectEqual(@as(usize, 2), state.match_count);
    try std.testing.expectEqual(PendingFilter.none, state.pending_filter);
}

test "ranking uses project names and ignores tmux markers" {
    const items = [_][]const u8{
        "archive-project",
        "my-project",
    };
    const entries = try test_entries(std.testing.allocator, &items, 2);
    defer deinit_test_entries(entries);
    var state = try State.init(std.testing.allocator, entries);
    defer state.deinit(std.testing.allocator);

    try state.append_query(std.testing.allocator, "project");
    state.refresh_matches();
    try std.testing.expectEqualStrings("my-project", state.selected_item().?);

    state.query.clearRetainingCapacity();
    state.folded_query.clearRetainingCapacity();
    try state.append_query(std.testing.allocator, "tmux");
    state.refresh_matches();
    try std.testing.expectEqual(@as(usize, 0), state.match_count);
}

test "remove_last_codepoint removes a complete UTF-8 codepoint" {
    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(std.testing.allocator);
    try query.appendSlice(std.testing.allocator, "café");

    remove_last_codepoint(&query);
    try std.testing.expectEqualStrings("caf", query.items);
}

test "append_query folds ASCII once for matching" {
    const items = [_][]const u8{"Scout-9"};
    const entries = try test_entries(std.testing.allocator, &items, 0);
    defer deinit_test_entries(entries);
    var state = try State.init(std.testing.allocator, entries);
    defer state.deinit(std.testing.allocator);

    try state.append_query(std.testing.allocator, "S9");

    try std.testing.expectEqualStrings("S9", state.query.items);
    try std.testing.expectEqualStrings("s9", state.folded_query.items);
}

test "layout places controls below the list" {
    const compact: Layout = .init(4);
    try std.testing.expectEqual(@as(usize, 1), compact.visible_rows());
    try std.testing.expectEqual(@as(u16, 2), compact.status_row);
    try std.testing.expectEqual(@as(u16, 3), compact.input_row);

    const full: Layout = .init(24);
    try std.testing.expectEqual(@as(usize, 21), full.visible_rows());
    try std.testing.expectEqual(@as(u16, 22), full.status_row);
    try std.testing.expectEqual(@as(u16, 23), full.input_row);
    try std.testing.expectEqual(@as(u16, 20), full.item_row(0));
    try std.testing.expectEqual(@as(u16, 0), full.item_row(20));
}

test "ranked matches pack five per cache line" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(State.RankedMatch));
}

test "picker accepts its project capacity" {
    const names = [_][]const u8{"a"} ** PROJECT_COUNT_MAX;
    const entries = try test_entries(std.testing.allocator, &names, 0);
    defer deinit_test_entries(entries);

    var state = try State.init(std.testing.allocator, entries);
    defer state.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, PROJECT_COUNT_MAX), state.match_count);
}

test "state rejects entries that bypass picker capacity" {
    const names = [_][]const u8{"a"} ** (PROJECT_COUNT_MAX + 1);
    const entries = try test_entries(std.testing.allocator, &names, 0);
    defer deinit_test_entries(entries);

    try std.testing.expectError(error.TooManyProjects, State.init(std.testing.allocator, entries));
}

test "input stops at the longest project name" {
    const names = [_][]const u8{ "ab", "c" };
    const entries = try test_entries(std.testing.allocator, &names, 0);
    defer deinit_test_entries(entries);
    var state = try State.init(std.testing.allocator, entries);
    defer state.deinit(std.testing.allocator);

    try state.append_query(std.testing.allocator, "ab");
    const action = try state.handle_key(std.testing.allocator, .{ .codepoint = 'c', .text = "c" });

    try std.testing.expectEqual(Action.ignore, action);
    try std.testing.expectEqualStrings("ab", state.query.items);
    try std.testing.expectEqualStrings("ab", state.folded_query.items);
}

fn test_entries(allocator: Allocator, project_names: []const []const u8, active_count: usize) !Entries.List {
    assert(active_count <= project_names.len);

    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    var offsets: std.ArrayList(u32) = .empty;
    defer offsets.deinit(allocator);

    const root = "/dev/";
    try bytes.writer.writeAll(root);
    try offsets.append(allocator, @intCast(bytes.written().len));
    for (project_names) |project_name| {
        try bytes.writer.writeAll(project_name);
        try offsets.append(allocator, @intCast(bytes.written().len));
    }

    const owned_bytes = try bytes.toOwnedSlice();
    errdefer allocator.free(owned_bytes);
    const owned_offsets = try offsets.toOwnedSlice(allocator);
    errdefer allocator.free(owned_offsets);
    const projects: Projects = .{
        .bytes = owned_bytes,
        .offsets = owned_offsets,
        .root_len = root.len,
    };
    return .{
        .projects = projects,
        .entry_count = project_names.len,
        .active_count = active_count,
    };
}

fn deinit_test_entries(entries: Entries.List) void {
    std.testing.allocator.free(entries.projects.bytes);
    std.testing.allocator.free(entries.projects.offsets);
}
