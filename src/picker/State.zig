//! UI-owned project, query, ranking, selection, and loading state.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const vaxis = @import("vaxis");

const Matcher = @import("Matcher.zig");
const Projects = @import("../Projects.zig");
const Tmux = @import("../Tmux.zig");

const PROJECT_NAME_BYTES_MAX = std.Io.Dir.max_name_bytes;
const QUERY_CAPACITY_EXPECTED = 64;

pub const Action = enum {
    ignore,
    redraw,
    accept,
    cancel,
};

/// Work deferred until the event queue has been drained.
pub const PendingFilter = enum {
    none,
    /// Search only the matches left by the previous query.
    narrow,
    /// Search every entry because deleting text can restore old matches.
    refresh,
};

pub const NameNormalizer = *const fn (
    project_name: []const u8,
    buffer: *[PROJECT_NAME_BYTES_MAX]u8,
) []const u8;

pub const State = struct {
    pub const Entry = struct {
        name: []const u8,
        session_active: bool = false,
    };

    pub const RankedMatch = struct {
        score: i32,
        entry_index: usize,
        match_span_size_bytes: u16,
        project_name_size_bytes: u16,
    };

    pub const Selection = struct {
        root_path: []const u8,
        project_name: []const u8,
    };

    /// Read-only state required to draw one frame.
    pub const RenderView = struct {
        entries: []const Entry,
        matches: []const RankedMatch,
        query: []const u8,
        folded_query: []const u8,
        selected_index: usize,
        first_visible_index: usize,
        discovery_complete: bool,

        pub fn entry(self: RenderView, match: RankedMatch) Entry {
            assert(match.entry_index < self.entries.len);
            return self.entries[match.entry_index];
        }

        pub fn visible_matches(self: RenderView, row_count: usize) []const RankedMatch {
            assert(self.first_visible_index <= self.matches.len);
            const end = @min(self.first_visible_index + row_count, self.matches.len);
            return self.matches[self.first_visible_index..end];
        }
    };

    root_path: ?[]const u8 = null,
    entries: std.ArrayList(Entry) = .empty,
    query: std.ArrayList(u8),
    folded_query: std.ArrayList(u8),
    /// One slot per entry. Only items before `match_count` are initialized matches.
    match_storage: std.ArrayList(RankedMatch) = .empty,
    partition_scratch: std.ArrayList(RankedMatch) = .empty,
    sessions: std.StringHashMapUnmanaged(void) = .empty,
    session_name_normalizer: ?NameNormalizer = null,

    match_count: usize = 0,
    selected_index: usize = 0,
    first_visible_index: usize = 0,

    pending_filter: PendingFilter = .none,
    ordering_pending: bool = false,
    selection_moved: bool = false,

    discovery_complete: bool = false,
    sessions_complete: bool = false,

    pub fn init(allocator: Allocator) !State {
        var query = try std.ArrayList(u8).initCapacity(allocator, QUERY_CAPACITY_EXPECTED);
        errdefer query.deinit(allocator);

        return .{
            .query = query,
            .folded_query = try std.ArrayList(u8).initCapacity(allocator, QUERY_CAPACITY_EXPECTED),
        };
    }

    pub fn deinit(self: *State, allocator: Allocator) void {
        self.entries.deinit(allocator);
        self.query.deinit(allocator);
        self.folded_query.deinit(allocator);
        self.match_storage.deinit(allocator);
        self.partition_scratch.deinit(allocator);
        self.sessions.deinit(allocator);
    }

    /// Adds a discovered batch and reports whether it changes the visible UI.
    pub fn append_batch(
        self: *State,
        allocator: Allocator,
        batch: *const Projects.Batch,
    ) !bool {
        if (self.root_path == null) self.root_path = batch.root_path;

        const first_new_entry = self.entries.items.len;
        const new_entry_count = batch.names.len;

        const total_entry_count = first_new_entry + new_entry_count;
        // Grow every fallible buffer before changing any logical length.
        try self.entries.ensureUnusedCapacity(allocator, new_entry_count);
        try self.partition_scratch.ensureTotalCapacity(allocator, total_entry_count);
        try self.match_storage.resize(allocator, total_entry_count);

        for (batch.names) |name| {
            self.entries.appendAssumeCapacity(.{
                .name = name,
                .session_active = self.session_is_active(name),
            });

            if (match_name(self, name, self.entries.items.len - 1)) |ranked| {
                self.match_storage.items[self.match_count] = ranked;
                self.match_count += 1;
            }
        }

        if (new_entry_count > 0) {
            const query_needs_ranking = self.query.items.len > 0;
            const batch_has_active_session = self.has_active_entries(first_new_entry);
            self.ordering_pending = self.ordering_pending or
                query_needs_ranking or batch_has_active_session;
        }

        return new_entry_count > 0;
    }

    /// Takes ownership of `sessions` and applies it to all discovered entries.
    pub fn set_sessions(
        self: *State,
        allocator: Allocator,
        sessions: std.StringHashMapUnmanaged(void),
        normalizer: ?NameNormalizer,
    ) !bool {
        assert(!self.sessions_complete);

        self.sessions = sessions;
        self.session_name_normalizer = normalizer;

        var entries_changed = false;

        for (self.entries.items) |*entry| {
            const active = self.session_is_active(entry.name);
            entries_changed = entries_changed or active != entry.session_active;
            entry.session_active = active;
        }

        if (entries_changed and self.query.items.len == 0) {
            try self.partition_scratch.ensureTotalCapacity(allocator, self.match_count);
            self.ordering_pending = true;
        }

        self.sessions_complete = true;
        return entries_changed;
    }

    pub fn finish_discovery(self: *State) void {
        self.discovery_complete = true;
    }

    pub fn handle_key(self: *State, allocator: Allocator, key: vaxis.Key) !Action {
        const cancel = key.matches(vaxis.Key.escape, .{}) or
            key.matches('c', .{ .ctrl = true });
        if (cancel) return .cancel;

        if (key.matches(vaxis.Key.enter, .{})) {
            self.apply_pending_updates();
            return if (self.match_count == 0) .ignore else .accept;
        }

        if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
            self.apply_pending_updates();
            return if (self.move_up()) .redraw else .ignore;
        }

        if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
            self.apply_pending_updates();
            return if (self.move_down()) .redraw else .ignore;
        }

        if (key.matches(vaxis.Key.backspace, .{})) {
            return self.handle_backspace();
        }

        const input = key.text orelse return .ignore;
        if (!accepts_text(key.mods, input)) return .ignore;
        assert(self.query.items.len <= PROJECT_NAME_BYTES_MAX);
        if (input.len > PROJECT_NAME_BYTES_MAX - self.query.items.len) return .ignore;

        try self.append_query(allocator, input);
        if (self.pending_filter == .none) self.pending_filter = .narrow;

        return .redraw;
    }

    fn move_up(self: *State) bool {
        if (self.selected_index + 1 >= self.match_count) return false;

        self.selected_index += 1;
        self.selection_moved = true;
        return true;
    }

    fn move_down(self: *State) bool {
        if (self.selected_index == 0) return false;

        self.selected_index -= 1;
        self.selection_moved = true;
        return true;
    }

    fn handle_backspace(self: *State) Action {
        if (self.query.items.len == 0) return .ignore;

        remove_last_codepoint(&self.query);
        remove_last_codepoint(&self.folded_query);
        self.pending_filter = .refresh;
        return .redraw;
    }

    /// Appends raw and folded query bytes as one logical update.
    fn append_query(self: *State, allocator: Allocator, input: []const u8) !void {
        assert(self.query.items.len == self.folded_query.items.len);

        const old_folded_len = self.folded_query.items.len;
        errdefer self.folded_query.items.len = old_folded_len;

        for (input) |byte| {
            try self.folded_query.append(allocator, std.ascii.toLower(byte));
        }
        try self.query.appendSlice(allocator, input);

        assert(self.query.items.len == self.folded_query.items.len);
    }

    /// Applies coalesced filter and ordering work after an event batch.
    pub fn apply_pending_updates(self: *State) void {
        const pending_filter = self.pending_filter;
        const ordering_pending = self.ordering_pending;

        self.pending_filter = .none;
        self.ordering_pending = false;

        switch (pending_filter) {
            .none => {},
            .narrow => self.narrow_matches(),
            .refresh => self.refresh_matches(),
        }

        // Both filter paths produce the final order for the current query.
        if (pending_filter == .none and ordering_pending) {
            self.order_matches();
        }
    }

    fn narrow_matches(self: *State) void {
        var count: usize = 0;

        for (self.match_storage.items[0..self.match_count]) |old| {
            if (match_name(self, self.entries.items[old.entry_index].name, old.entry_index)) |ranked| {
                self.match_storage.items[count] = ranked;
                count += 1;
            }
        }

        self.match_count = count;
        self.sort_ranked();
        self.reset_selection();
    }

    fn refresh_matches(self: *State) void {
        self.match_count = 0;

        for (self.entries.items, 0..) |entry, index| {
            if (match_name(self, entry.name, index)) |ranked| {
                self.match_storage.items[self.match_count] = ranked;
                self.match_count += 1;
            }
        }

        self.order_matches();
        self.reset_selection();
    }

    fn order_matches(self: *State) void {
        if (self.query.items.len == 0) {
            self.stable_partition();
        } else {
            self.sort_ranked();
        }
    }

    fn stable_partition(self: *State) void {
        assert(self.partition_scratch.capacity >= self.match_count);

        const selected_entry = self.selected_entry_index();
        self.partition_scratch.items.len = 0;

        for (self.match_storage.items[0..self.match_count]) |match| {
            if (self.entries.items[match.entry_index].session_active) {
                self.partition_scratch.appendAssumeCapacity(match);
            }
        }
        for (self.match_storage.items[0..self.match_count]) |match| {
            if (!self.entries.items[match.entry_index].session_active) {
                self.partition_scratch.appendAssumeCapacity(match);
            }
        }

        @memcpy(self.match_storage.items[0..self.match_count], self.partition_scratch.items);
        self.restore_selection(selected_entry);
    }

    fn sort_ranked(self: *State) void {
        const selected_entry = self.selected_entry_index();
        std.mem.sortUnstable(RankedMatch, self.match_storage.items[0..self.match_count], {}, less_than);
        self.restore_selection(selected_entry);
    }

    fn less_than(_: void, left: RankedMatch, right: RankedMatch) bool {
        if (left.score != right.score) return left.score > right.score;

        if (left.match_span_size_bytes != right.match_span_size_bytes) {
            return left.match_span_size_bytes < right.match_span_size_bytes;
        }
        if (left.project_name_size_bytes != right.project_name_size_bytes) {
            return left.project_name_size_bytes < right.project_name_size_bytes;
        }

        return left.entry_index < right.entry_index;
    }

    fn selected_entry_index(self: State) ?usize {
        if (!self.selection_moved or self.match_count == 0) return null;
        assert(self.selected_index < self.match_count);
        return self.match_storage.items[self.selected_index].entry_index;
    }

    fn restore_selection(self: *State, selected_entry: ?usize) void {
        if (selected_entry) |entry_index| {
            for (self.match_storage.items[0..self.match_count], 0..) |match, index| {
                if (match.entry_index == entry_index) {
                    self.selected_index = index;
                    return;
                }
            }
        }

        self.reset_selection();
    }

    fn reset_selection(self: *State) void {
        self.selected_index = 0;
        self.first_visible_index = 0;
        self.selection_moved = false;
    }

    fn has_active_entries(self: State, first_entry: usize) bool {
        for (self.entries.items[first_entry..]) |entry| {
            if (entry.session_active) return true;
        }
        return false;
    }

    fn session_is_active(self: State, project_name: []const u8) bool {
        const normalizer = self.session_name_normalizer orelse
            return self.sessions.contains(project_name);

        var buffer: [PROJECT_NAME_BYTES_MAX]u8 = undefined;
        return self.sessions.contains(normalizer(project_name, &buffer));
    }

    /// Returns the selected project name, or null when nothing matches.
    pub fn selected_item(self: State) ?[]const u8 {
        if (self.match_count == 0) return null;
        assert(self.selected_index < self.match_count);
        return self.entries.items[self.match_storage.items[self.selected_index].entry_index].name;
    }

    /// Returns the complete selected project, if one exists.
    pub fn selection(self: State) ?Selection {
        const project_name = self.selected_item() orelse return null;
        assert(self.root_path != null);

        return .{
            .root_path = self.root_path.?,
            .project_name = project_name,
        };
    }

    /// Borrows the slices needed by the renderer for the current frame.
    pub fn render_view(self: State) RenderView {
        assert(self.match_count <= self.match_storage.items.len);

        return .{
            .entries = self.entries.items,
            .matches = self.match_storage.items[0..self.match_count],
            .query = self.query.items,
            .folded_query = self.folded_query.items,
            .selected_index = self.selected_index,
            .first_visible_index = self.first_visible_index,
            .discovery_complete = self.discovery_complete,
        };
    }

    /// Moves the visible window just enough to contain the selection.
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

fn match_name(state: *const State, name: []const u8, index: usize) ?State.RankedMatch {
    const result: Matcher.Result = if (state.query.items.len == 0)
        .{ .score = 0, .start = 0, .end = 0 }
    else
        Matcher.rank_folded(state.query.items, state.folded_query.items, name) orelse return null;

    return .{
        .score = result.score,
        .entry_index = index,
        .match_span_size_bytes = @intCast(result.end - result.start),
        .project_name_size_bytes = @intCast(name.len),
    };
}

fn accepts_text(mods: vaxis.Key.Modifiers, text: []const u8) bool {
    if (mods.ctrl or mods.alt or mods.super or mods.hyper or mods.meta) return false;
    return text.len > 0 and text[0] >= ' ' and text[0] != 0x7f;
}

fn remove_last_codepoint(query: *std.ArrayList(u8)) void {
    assert(query.items.len > 0);

    var len = query.items.len - 1;
    while (len > 0 and query.items[len] & 0xc0 == 0x80) len -= 1;
    query.items.len = len;
}

fn test_state(names: []const []const u8) !State {
    var state = try State.init(std.testing.allocator);
    errdefer state.deinit(std.testing.allocator);

    const batch: Projects.Batch = .{ .root_path = "/", .names = names };
    _ = try state.append_batch(std.testing.allocator, &batch);
    return state;
}

fn set_test_sessions(
    state: *State,
    names: []const []const u8,
    normalizer: ?NameNormalizer,
) !bool {
    var sessions: std.StringHashMapUnmanaged(void) = .empty;

    for (names) |name| {
        sessions.put(std.testing.allocator, name, {}) catch |err| {
            sessions.deinit(std.testing.allocator);
            return err;
        };
    }
    // State owns the map as soon as set_sessions is called, including on error.
    return state.set_sessions(std.testing.allocator, sessions, normalizer);
}

fn type_query(state: *State, text: []const u8) !void {
    for (text) |byte| {
        const input = [1]u8{byte};
        _ = try state.handle_key(std.testing.allocator, .{
            .codepoint = byte,
            .text = &input,
        });
    }
}

fn expect_match_order(state: State, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, state.match_count);

    for (expected, state.match_storage.items[0..state.match_count]) |name, match| {
        try std.testing.expectEqualStrings(name, state.entries.items[match.entry_index].name);
    }
}

test "empty query partitions active entries stably" {
    var state = try test_state(&.{ "a", "b", "c", "d" });
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(try set_test_sessions(&state, &.{ "b", "d" }, null));
    state.apply_pending_updates();

    try expect_match_order(state, &.{ "b", "d", "a", "c" });
}

test "typed query ignores active state and coalesces filtering" {
    var state = try test_state(&.{ "source", "scout", "other" });
    defer state.deinit(std.testing.allocator);

    _ = try set_test_sessions(&state, &.{"source"}, null);
    try type_query(&state, "sc");

    try std.testing.expectEqual(PendingFilter.narrow, state.pending_filter);
    state.apply_pending_updates();

    try std.testing.expectEqual(@as(usize, 2), state.match_count);
    try std.testing.expectEqualStrings("scout", state.selected_item().?);
    try std.testing.expect(state.entries.items[0].session_active);
    try std.testing.expectEqual(PendingFilter.none, state.pending_filter);
    try std.testing.expect(!state.ordering_pending);
}

test "sessions arriving before projects mark later batches immediately" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(!try set_test_sessions(
        &state,
        &.{"my_project"},
        Tmux.session_name,
    ));
    try std.testing.expect(state.sessions_complete);

    const batch: Projects.Batch = .{ .root_path = "/", .names = &.{ "other", "my.project" } };
    _ = try state.append_batch(std.testing.allocator, &batch);
    state.apply_pending_updates();
    try std.testing.expect(state.entries.items[1].session_active);
    try std.testing.expectEqualStrings("my.project", state.selected_item().?);
}

test "empty session completion has no visible effect" {
    var state = try test_state(&.{"project"});
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(!try set_test_sessions(&state, &.{}, null));
    try std.testing.expect(state.sessions_complete);
    try std.testing.expect(!state.ordering_pending);
}

test "several batches and sessions coalesce into one stable partition" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit(std.testing.allocator);
    const first: Projects.Batch = .{ .root_path = "/", .names = &.{ "a", "b" } };
    const second: Projects.Batch = .{ .root_path = "/", .names = &.{ "c", "d" } };
    _ = try state.append_batch(std.testing.allocator, &first);
    _ = try state.append_batch(std.testing.allocator, &second);
    _ = try set_test_sessions(&state, &.{ "b", "d" }, null);
    try std.testing.expect(state.ordering_pending);

    state.apply_pending_updates();

    try expect_match_order(state, &.{ "b", "d", "a", "c" });
    try std.testing.expect(!state.ordering_pending);
}

test "late sessions preserve an explicitly moved selection" {
    var state = try test_state(&.{ "a", "b", "c" });
    defer state.deinit(std.testing.allocator);

    _ = try state.handle_key(std.testing.allocator, .{ .codepoint = vaxis.Key.up });
    try std.testing.expectEqualStrings("b", state.selected_item().?);

    _ = try set_test_sessions(&state, &.{"c"}, null);
    state.apply_pending_updates();

    try std.testing.expectEqualStrings("b", state.selected_item().?);
    try std.testing.expectEqualStrings("c", state.entries.items[state.match_storage.items[0].entry_index].name);
}

test "query shrink rebuilds matches excluded by query growth" {
    var state = try test_state(&.{ "scout", "source", "other" });
    defer state.deinit(std.testing.allocator);

    try type_query(&state, "scx");
    state.apply_pending_updates();
    try std.testing.expectEqual(@as(usize, 0), state.match_count);

    _ = try state.handle_key(std.testing.allocator, .{ .codepoint = vaxis.Key.backspace });
    try std.testing.expectEqual(PendingFilter.refresh, state.pending_filter);
    state.apply_pending_updates();
    try std.testing.expectEqual(@as(usize, 2), state.match_count);
}
