//! Loading and ready-state transitions for the picker view.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const vaxis = @import("vaxis");

const Entries = @import("../Entries.zig");
const Input = @import("Input.zig");
const Projects = @import("../../Projects.zig");
const State = @import("State.zig").State;
const Action = @import("Types.zig").Action;
const Selection = @import("Types.zig").Selection;

const QUERY_BYTES_EXPECTED = 64;
const handle_loading_key = Input.handle_loading_key;
const valid_prefix_len = Input.valid_prefix_len;

/// Picker state that spans the loading and ready phases.
pub const ViewState = struct {
    /// Query accepted before the first batch makes ranked state available.
    loading_query: std.ArrayList(u8),
    batches: std.ArrayList(*Projects.Batch),
    /// Flat lookup table from picker entries to batch records.
    locations: std.ArrayList(Entries.EntryLocation),
    entry_count: usize = 0,
    discovery_complete: bool = false,
    enrichment_complete: bool = false,
    /// Whether published terminal session state may have changed match order.
    ordering_pending: bool = false,
    ready: ?State = null,

    pub fn init(allocator: Allocator) !ViewState {
        var loading_query = try std.ArrayList(u8).initCapacity(allocator, QUERY_BYTES_EXPECTED);
        errdefer loading_query.deinit(allocator);
        var batches = try std.ArrayList(*Projects.Batch).initCapacity(allocator, Projects.BATCH_SIZE);
        errdefer batches.deinit(allocator);
        return .{
            .loading_query = loading_query,
            .batches = batches,
            .locations = try std.ArrayList(Entries.EntryLocation).initCapacity(allocator, Projects.BATCH_SIZE),
        };
    }

    pub fn deinit(self: *ViewState, allocator: Allocator) void {
        self.loading_query.deinit(allocator);
        self.batches.deinit(allocator);
        self.locations.deinit(allocator);
        if (self.ready) |*ready| ready.deinit(allocator);
    }

    /// Applies pending background updates, then handles one key.
    pub fn handle_key(self: *ViewState, allocator: Allocator, key: vaxis.Key) !Action {
        self.apply_pending_updates();
        if (self.ready) |*ready| return ready.handle_key(allocator, key);
        return handle_loading_key(&self.loading_query, allocator, key);
    }

    /// Adds the next discovery batch and makes its projects searchable.
    pub fn append_batch(self: *ViewState, allocator: Allocator, batch: *Projects.Batch) !void {
        assert(batch.batch_index == self.batches.items.len);

        const old_entry_count = self.entry_count;
        const old_location_count = self.locations.items.len;
        errdefer self.locations.items.len = old_location_count;
        for (0..batch.projects.len) |name_index| {
            try self.locations.append(allocator, .{ .batch = batch, .name_index = name_index });
        }
        try self.batches.append(allocator, batch);
        errdefer self.batches.items.len -= 1;

        const entries: Entries.List = .{
            .batches = self.batches.items,
            .locations = self.locations.items,
        };

        if (self.ready) |*ready| {
            try ready.append_entries(allocator, entries, old_entry_count);
            self.entry_count = self.locations.items.len;
            self.ordering_pending = true;
            return;
        }

        self.ready = try State.init(allocator, entries);
        self.entry_count = self.locations.items.len;
        const ready = &self.ready.?;
        const query_len = valid_prefix_len(self.loading_query.items, ready.project_name_size_bytes_max);

        if (query_len > 0) {
            try ready.append_query(allocator, self.loading_query.items[0..query_len]);
            ready.refresh_matches();
        }
    }

    /// Observes published backend metadata and schedules a stable reorder.
    pub fn finish_batch_backend_enrichment(self: *ViewState, batch: *Projects.Batch) void {
        assert(batch.batch_index < self.batches.items.len);
        assert(self.batches.items[batch.batch_index] == batch);
        assert(batch.backend_enrichment_complete.load(.acquire));
        self.ordering_pending = true;
    }

    /// Verifies that a received batch has published its Git metadata.
    pub fn finish_batch_git_enrichment(self: *ViewState, batch: *Projects.Batch) void {
        assert(batch.batch_index < self.batches.items.len);
        assert(self.batches.items[batch.batch_index] == batch);
        assert(batch.git_enrichment_complete.load(.acquire));
    }

    pub fn selection(self: ViewState) ?Selection {
        const ready = self.ready orelse return null;
        const location = ready.selected_location() orelse return null;
        return .{
            .root_path = location.batch.root_path,
            .project_name = location.batch.projects.slice().items(.name)[location.name_index],
        };
    }

    /// Applies one deferred query filter or enrichment-driven reorder.
    pub fn apply_pending_updates(self: *ViewState) void {
        const ready = if (self.ready) |*ready| ready else return;
        if (ready.pending_filter != .none) {
            ready.apply_pending_filter();
            self.ordering_pending = false;
        } else if (self.ordering_pending) {
            ready.sort_matches_preserving_selection();
            self.ordering_pending = false;
        }
    }
};
