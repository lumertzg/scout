//! Picker match state and ranking.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const vaxis = @import("vaxis");

const Entries = @import("../Entries.zig");
const Input = @import("Input.zig");
const Matcher = @import("../Matcher.zig");
const Projects = @import("../../Projects.zig");
const Action = @import("Types.zig").Action;

const PROJECT_NAME_BYTES_MAX = std.Io.Dir.max_name_bytes;
const QUERY_BYTES_EXPECTED = 64;

comptime {
    assert(PROJECT_NAME_BYTES_MAX <= std.math.maxInt(u16));
}

const accepts_text = Input.accepts_text;
const remove_last_codepoint = Input.remove_last_codepoint;

/// Deferred update required after editing the query.
pub const PendingFilter = enum {
    none,
    /// Search only the current matches after appending text.
    narrow,
    /// Search every entry after deleting text.
    refresh,
};

/// Search, ordering, selection, and scrolling state for loaded entries.
pub const State = struct {
    /// Cached rank data for one matching entry.
    pub const RankedMatch = struct {
        score: i32,
        entry_index: usize,
        /// Byte width from the first through last matched byte.
        match_span_size_bytes: u16,
        /// Full project-name byte length used as a ranking tie-breaker.
        project_name_size_bytes: u16,
    };

    const SortContext = struct {
        entries: Entries.List,
        query_empty: bool,
    };

    entries: Entries.List,

    query: std.ArrayList(u8) = .empty,
    /// ASCII-lowercase query bytes used by the matcher.
    folded_query: std.ArrayList(u8) = .empty,

    /// Scratch storage sized for every entry; only `match_count` items are live.
    matches: std.ArrayList(RankedMatch),
    /// Largest project name, used to bound query and position buffers.
    project_name_size_bytes_max: usize,

    match_count: usize = 0,
    selected_index: usize = 0,
    first_visible_index: usize = 0,

    /// Screen row of the first drawn entry, used to clear stale rows.
    first_drawn_row: ?u16 = null,
    /// Query update delayed until input handling or drawing needs fresh results.
    pending_filter: PendingFilter = .none,

    pub fn init(allocator: Allocator, entries: Entries.List) !State {
        entries.assert_valid();

        const entry_count = entries.len();
        var matches = try std.ArrayList(RankedMatch).initCapacity(allocator, Projects.BATCH_SIZE);
        errdefer matches.deinit(allocator);

        try matches.resize(allocator, entry_count);

        var project_name_size_bytes_max: usize = 0;
        for (0..entry_count) |entry_index| {
            const project_name = entries.entry_name(entry_index);
            project_name_size_bytes_max = @max(project_name_size_bytes_max, project_name.len);
        }

        if (project_name_size_bytes_max > PROJECT_NAME_BYTES_MAX) return error.ProjectNameTooLong;

        var query = try std.ArrayList(u8).initCapacity(allocator, @min(project_name_size_bytes_max, QUERY_BYTES_EXPECTED));
        errdefer query.deinit(allocator);

        const folded_query = try std.ArrayList(u8).initCapacity(allocator, @min(project_name_size_bytes_max, QUERY_BYTES_EXPECTED));

        var state: State = .{
            .entries = entries,
            .query = query,
            .folded_query = folded_query,
            .matches = matches,
            .project_name_size_bytes_max = project_name_size_bytes_max,
        };

        state.refresh_matches();

        return state;
    }

    pub fn deinit(self: *State, allocator: Allocator) void {
        self.query.deinit(allocator);
        self.folded_query.deinit(allocator);
        self.matches.deinit(allocator);
    }

    /// Adds entries appended to the backing list without rescanning old misses.
    pub fn append_entries(
        self: *State,
        allocator: Allocator,
        entries: Entries.List,
        old_entry_count: usize,
    ) !void {
        entries.assert_valid();
        assert(old_entry_count <= entries.len());

        var project_name_size_bytes_max = self.project_name_size_bytes_max;
        for (old_entry_count..entries.len()) |entry_index| {
            project_name_size_bytes_max = @max(project_name_size_bytes_max, entries.entry_name(entry_index).len);
        }

        if (project_name_size_bytes_max > PROJECT_NAME_BYTES_MAX) return error.ProjectNameTooLong;

        try self.matches.resize(allocator, entries.len());
        self.entries = entries;
        self.project_name_size_bytes_max = project_name_size_bytes_max;

        for (old_entry_count..entries.len()) |entry_index| {
            const project_name = entries.entry_name(entry_index);
            const result = if (self.query.items.len == 0)
                Matcher.Result{ .score = 0, .start = 0, .end = 0 }
            else
                Matcher.rank_folded(self.query.items, self.folded_query.items, project_name) orelse continue;

            self.matches.items[self.match_count] = .{
                .entry_index = entry_index,
                .score = result.score,
                .match_span_size_bytes = @intCast(result.end - result.start),
                .project_name_size_bytes = @intCast(project_name.len),
            };
            self.match_count += 1;
        }
    }

    pub fn handle_key(self: *State, allocator: Allocator, key: vaxis.Key) !Action {
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
        assert(self.query.items.len <= self.project_name_size_bytes_max);

        if (text.len > self.project_name_size_bytes_max - self.query.items.len) return .ignore;

        try self.append_query(allocator, text);
        if (self.pending_filter == .none) self.pending_filter = .narrow;

        return .redraw;
    }

    /// Appends query bytes and their ASCII-folded form atomically on error.
    pub fn append_query(self: *State, allocator: Allocator, text: []const u8) !void {
        assert(self.query.items.len == self.folded_query.items.len);
        assert(text.len <= self.project_name_size_bytes_max - self.query.items.len);

        const folded_len = self.folded_query.items.len;
        errdefer self.folded_query.items.len = folded_len;

        for (text) |byte| {
            try self.folded_query.append(allocator, std.ascii.toLower(byte));
        }

        try self.query.appendSlice(allocator, text);
        assert(self.query.items.len == self.folded_query.items.len);
    }

    /// Rebuilds and sorts matches from every entry.
    pub fn refresh_matches(self: *State) void {
        assert(self.query.items.len == self.folded_query.items.len);
        assert(self.matches.items.len == self.entries.len());

        if (self.query.items.len == 0) {
            for (self.matches.items, 0..) |*match, entry_index| {
                match.* = .{
                    .entry_index = entry_index,
                    .score = 0,
                    .match_span_size_bytes = 0,
                    .project_name_size_bytes = @intCast(self.entries.entry_name(entry_index).len),
                };
            }

            self.match_count = self.entries.len();
            self.sort_matches();
            self.reset_selection();

            return;
        }

        self.match_count = 0;
        const query = self.query.items;
        const folded_query = self.folded_query.items;

        for (0..self.entries.len()) |entry_index| {
            const project_name = self.entries.entry_name(entry_index);
            const result = Matcher.rank_folded(query, folded_query, project_name) orelse continue;

            self.matches.items[self.match_count] = .{
                .entry_index = entry_index,
                .score = result.score,
                .match_span_size_bytes = @intCast(result.end - result.start),
                .project_name_size_bytes = @intCast(project_name.len),
            };

            self.match_count += 1;
        }

        assert(self.match_count <= self.matches.items.len);
        self.sort_matches();
        self.reset_selection();
    }

    /// Refilters current matches after the query only grew.
    pub fn narrow_matches(self: *State) void {
        assert(self.query.items.len == self.folded_query.items.len);
        assert(self.match_count <= self.matches.items.len);

        var narrowed_count: usize = 0;
        const query = self.query.items;
        const folded_query = self.folded_query.items;

        for (self.matches.items[0..self.match_count]) |match| {
            const project_name = self.entries.entry_name(match.entry_index);
            const result = Matcher.rank_folded(query, folded_query, project_name) orelse continue;

            self.matches.items[narrowed_count] = .{
                .entry_index = match.entry_index,
                .score = result.score,
                .match_span_size_bytes = @intCast(result.end - result.start),
                .project_name_size_bytes = match.project_name_size_bytes,
            };

            narrowed_count += 1;
        }

        assert(narrowed_count <= self.match_count);

        self.match_count = narrowed_count;
        self.sort_matches();
        self.reset_selection();
    }

    pub fn apply_pending_filter(self: *State) void {
        const pending_filter = self.pending_filter;
        self.pending_filter = .none;

        switch (pending_filter) {
            .none => {},
            .narrow => self.narrow_matches(),
            .refresh => self.refresh_matches(),
        }

        assert(self.query.items.len == self.folded_query.items.len);
    }

    /// Sorts live matches by session state, score, compactness, then discovery order.
    pub fn sort_matches(self: *State) void {
        assert(self.match_count <= self.matches.items.len);
        const context: SortContext = .{
            .entries = self.entries,
            .query_empty = self.query.items.len == 0,
        };
        std.mem.sortUnstable(RankedMatch, self.matches.items[0..self.match_count], context, less_than);
    }

    fn less_than(context: SortContext, left: RankedMatch, right: RankedMatch) bool {
        const left_active = context.entries.entry_is_tmux_session_active(left.entry_index);
        const right_active = context.entries.entry_is_tmux_session_active(right.entry_index);

        if (left_active != right_active) return left_active;
        if (context.query_empty) return left.entry_index < right.entry_index;
        if (left.score != right.score) return left.score > right.score;

        if (left.match_span_size_bytes != right.match_span_size_bytes) {
            return left.match_span_size_bytes < right.match_span_size_bytes;
        }

        if (left.project_name_size_bytes != right.project_name_size_bytes) {
            return left.project_name_size_bytes < right.project_name_size_bytes;
        }

        return left.entry_index < right.entry_index;
    }

    /// Reorders matches while retaining the selected project when possible.
    pub fn sort_matches_preserving_selection(self: *State) void {
        const selection_is_initial = self.selected_index == 0;
        const selected_entry_location = self.selected_location();
        const selected_index = self.selected_index;
        self.sort_matches();

        if (selection_is_initial) {
            self.reset_selection();
            return;
        }

        self.restore_selection(selected_entry_location, selected_index);
    }

    pub fn selected_location(self: State) ?Entries.EntryLocation {
        if (self.match_count == 0) return null;
        assert(self.selected_index < self.match_count);

        return self.entries.locate_entry(self.matches.items[self.selected_index].entry_index);
    }

    /// Restores a project after sorting, falling back to its prior list index.
    pub fn restore_selection(self: *State, entry_location: ?Entries.EntryLocation, previous_selected_index: usize) void {
        if (self.match_count == 0) {
            self.reset_selection();
            return;
        }

        if (entry_location) |expected| {
            for (self.matches.items[0..self.match_count], 0..) |match, match_index| {
                const actual = self.entries.locate_entry(match.entry_index) orelse unreachable;
                if (actual.batch == expected.batch and actual.name_index == expected.name_index) {
                    self.selected_index = match_index;
                    self.first_visible_index = @min(self.first_visible_index, match_index);
                    return;
                }
            }
        }

        self.selected_index = @min(previous_selected_index, self.match_count - 1);
        self.first_visible_index = @min(self.first_visible_index, self.selected_index);
    }

    pub fn reset_selection(self: *State) void {
        self.selected_index = 0;
        self.first_visible_index = 0;
    }

    /// Moves one screen row up in the bottom-up project list.
    pub fn move_up(self: *State) bool {
        if (self.match_count > 0) assert(self.selected_index < self.match_count);
        // Larger match indexes render on higher rows because the list grows up
        // from the prompt.
        if (self.selected_index + 1 >= self.match_count) return false;
        self.selected_index += 1;
        return true;
    }

    /// Moves one screen row down in the bottom-up project list.
    pub fn move_down(self: *State) bool {
        if (self.match_count > 0) assert(self.selected_index < self.match_count);
        if (self.selected_index == 0) return false;
        self.selected_index -= 1;
        return true;
    }

    pub fn selected_item(self: State) ?[]const u8 {
        if (self.match_count == 0) return null;
        assert(self.selected_index < self.match_count);
        return self.entries.entry_name(self.matches.items[self.selected_index].entry_index);
    }

    /// Adjusts the scroll window until it contains the selection.
    pub fn sync_scroll(self: *State, visible_rows: usize) void {
        if (visible_rows == 0 or self.match_count == 0) return;
        assert(self.selected_index < self.match_count);

        if (self.selected_index < self.first_visible_index) {
            self.first_visible_index = self.selected_index;
        } else if (self.selected_index >= self.first_visible_index + visible_rows) {
            self.first_visible_index = self.selected_index - visible_rows + 1;
        }
    }
};
