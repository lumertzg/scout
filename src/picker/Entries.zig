//! Builds display entries for the picker.

const std = @import("std");
const assert = std.debug.assert;

const Git = @import("../git.zig");
const Projects = @import("../Projects.zig");

pub const EntryLocation = struct {
    batch: *Projects.Batch,
    name_index: usize,
};

pub const List = struct {
    batches: []const *Projects.Batch,
    locations: []const EntryLocation,

    pub fn len(self: List) usize {
        return self.locations.len;
    }

    pub fn entry_name(self: List, entry_index: usize) []const u8 {
        assert(entry_index < self.locations.len);
        const location = self.locate_entry(entry_index) orelse unreachable;
        return location.batch.projects.slice().items(.name)[location.name_index];
    }

    pub fn entry_is_tmux_session_active(self: List, entry_index: usize) bool {
        assert(entry_index < self.locations.len);
        const location = self.locate_entry(entry_index) orelse unreachable;
        if (!location.batch.tmux_enrichment_complete.load(.acquire)) return false;

        return location.batch.projects.slice().items(.tmux_session_active)[location.name_index];
    }

    pub fn entry_git_branch(self: List, entry_index: usize) ?[]const u8 {
        assert(entry_index < self.locations.len);
        const location = self.locate_entry(entry_index) orelse unreachable;
        if (!location.batch.git_enrichment_complete.load(.acquire)) return null;

        return location.batch.projects.slice().items(.git_branch)[location.name_index];
    }

    pub fn entry_git_state(self: List, entry_index: usize) Git.State {
        assert(entry_index < self.locations.len);
        const location = self.locate_entry(entry_index) orelse unreachable;
        if (!location.batch.git_enrichment_complete.load(.acquire)) return .{};

        return location.batch.projects.slice().items(.git_state)[location.name_index];
    }

    pub fn locate_entry(self: List, entry_index: usize) ?EntryLocation {
        if (entry_index >= self.locations.len) return null;
        return self.locations[entry_index];
    }

    /// Verifies the cached count and batch ordering at state boundaries.
    pub fn assert_valid(self: List) void {
        var location_index: usize = 0;
        for (self.batches, 0..) |batch, batch_index| {
            assert(batch.batch_index == batch_index);
            for (0..batch.projects.len) |name_index| {
                assert(location_index < self.locations.len);
                const location = self.locations[location_index];
                assert(location.batch == batch);
                assert(location.name_index == name_index);
                location_index += 1;
            }
        }
        assert(location_index == self.locations.len);
    }
};

test "empty and multi-batch lists locate names across boundaries" {
    const empty: List = .{ .batches = &.{}, .locations = &.{} };
    try std.testing.expectEqual(@as(usize, 0), empty.len());

    var batches = [_]Projects.Batch{
        try test_batch(std.testing.allocator, 0, &.{ "alpha", "beta" }),
        try test_batch(std.testing.allocator, 1, &.{"gamma"}),
    };
    defer deinit_test_batch(std.testing.allocator, &batches[1]);
    defer deinit_test_batch(std.testing.allocator, &batches[0]);
    const batch_pointers = [_]*Projects.Batch{ &batches[0], &batches[1] };
    const locations = [_]EntryLocation{
        .{ .batch = &batches[0], .name_index = 0 },
        .{ .batch = &batches[0], .name_index = 1 },
        .{ .batch = &batches[1], .name_index = 0 },
    };
    const list: List = .{ .batches = &batch_pointers, .locations = &locations };

    try std.testing.expectEqualStrings("alpha", list.entry_name(0));
    try std.testing.expectEqualStrings("beta", list.entry_name(1));
    try std.testing.expectEqualStrings("gamma", list.entry_name(2));
    try std.testing.expectEqual(&batches[0], list.locate_entry(1).?.batch);
    try std.testing.expectEqual(@as(usize, 1), list.locate_entry(1).?.name_index);
    try std.testing.expectEqual(&batches[1], list.locate_entry(2).?.batch);
    try std.testing.expectEqual(@as(usize, 0), list.locate_entry(2).?.name_index);
    try std.testing.expectEqual(@as(?EntryLocation, null), list.locate_entry(3));
}

test "active state is hidden until enrichment is published" {
    var batch = try test_batch(std.testing.allocator, 0, &.{ "alpha", "beta" });
    defer deinit_test_batch(std.testing.allocator, &batch);
    const batch_pointers = [_]*Projects.Batch{&batch};
    const locations = [_]EntryLocation{
        .{ .batch = &batch, .name_index = 0 },
        .{ .batch = &batch, .name_index = 1 },
    };
    const list: List = .{ .batches = &batch_pointers, .locations = &locations };

    batch.projects.slice().items(.tmux_session_active)[1] = true;
    try std.testing.expect(!list.entry_is_tmux_session_active(1));

    batch.tmux_enrichment_complete.store(true, .release);
    try std.testing.expect(list.entry_is_tmux_session_active(1));
    try std.testing.expect(!list.entry_is_tmux_session_active(0));
}

test "git metadata is hidden until enrichment is published" {
    var batch = try test_batch(std.testing.allocator, 0, &.{"alpha"});
    defer deinit_test_batch(std.testing.allocator, &batch);
    const batch_pointers = [_]*Projects.Batch{&batch};
    const locations = [_]EntryLocation{.{ .batch = &batch, .name_index = 0 }};
    const list: List = .{ .batches = &batch_pointers, .locations = &locations };

    batch.projects.slice().items(.git_branch)[0] = "main";
    batch.projects.slice().items(.git_state)[0].modified = true;
    try std.testing.expectEqual(@as(?[]const u8, null), list.entry_git_branch(0));
    try std.testing.expect(list.entry_git_state(0).is_empty());

    batch.git_enrichment_complete.store(true, .release);
    try std.testing.expectEqualStrings("main", list.entry_git_branch(0).?);
    try std.testing.expect(list.entry_git_state(0).modified);
}

fn test_batch(allocator: std.mem.Allocator, batch_index: usize, names: []const []const u8) !Projects.Batch {
    var projects = try std.MultiArrayList(Projects.Project).initCapacity(allocator, names.len);
    errdefer projects.deinit(allocator);
    for (names) |name| projects.appendAssumeCapacity(.{ .name = name });
    return .{
        .batch_index = batch_index,
        .root_path = "/dev/",
        .projects = projects,
    };
}

fn deinit_test_batch(allocator: std.mem.Allocator, batch: *Projects.Batch) void {
    batch.projects.deinit(allocator);
}
