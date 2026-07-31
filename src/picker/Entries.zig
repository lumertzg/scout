//! Builds display entries for the picker.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Projects = @import("../Projects.zig");
const Tmux = @import("../Tmux.zig");

pub const List = struct {
    projects: Projects,
    entry_count: usize,
    project_indices: ?[]const u32 = null,
    active_count: usize = 0,

    pub inline fn len(self: List) usize {
        assert(self.entry_count <= self.projects.len());
        return self.entry_count;
    }

    pub inline fn name(self: List, entry_index: usize) []const u8 {
        return self.projects.name(self.project_index(entry_index));
    }

    pub inline fn is_active(self: List, entry_index: usize) bool {
        assert(entry_index < self.len());
        return entry_index < self.active_count;
    }

    pub inline fn project_index(self: List, entry_index: usize) usize {
        assert(entry_index < self.len());
        if (self.project_indices) |project_indices| {
            assert(project_indices.len == self.len());
            assert(project_indices[entry_index] < self.len());
            return project_indices[entry_index];
        }
        return entry_index;
    }
};

pub fn from_projects(projects: Projects) List {
    return .{
        .projects = projects,
        .entry_count = @min(projects.len(), Projects.PROJECT_COUNT_PICKER_MAX),
    };
}

pub fn with_active_sessions(arena: Allocator, projects: Projects, sessions: Tmux.SessionSet) !List {
    const entry_count = @min(projects.len(), Projects.PROJECT_COUNT_PICKER_MAX);
    assert(entry_count <= std.math.maxInt(u32));

    const project_indices = try arena.alloc(u32, entry_count);
    var active_count: usize = 0;
    var inactive_index = project_indices.len;
    var session_buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;

    for (0..entry_count) |project_index| {
        const name = projects.name(project_index);
        const session_name = Tmux.session_name_buffered(name, &session_buffer);

        if (sessions.contains(session_name)) {
            project_indices[active_count] = @intCast(project_index);
            active_count += 1;
        } else {
            inactive_index -= 1;
            project_indices[inactive_index] = @intCast(project_index);
        }
    }

    assert(active_count == inactive_index);
    std.mem.reverse(u32, project_indices[active_count..]);

    return .{
        .projects = projects,
        .entry_count = entry_count,
        .project_indices = project_indices,
        .active_count = active_count,
    };
}

test "plain entries preserve project order" {
    const projects: Projects = .{
        .bytes = "/dev/scoutnewother",
        .offsets = &.{ 5, 10, 13, 18 },
        .root_len = 5,
    };
    const list = from_projects(projects);

    try std.testing.expectEqual(@as(usize, 3), list.len());
    try std.testing.expectEqualStrings("scout", list.name(0));
    try std.testing.expectEqualStrings("new", list.name(1));
    try std.testing.expectEqualStrings("other", list.name(2));
}

test "plain entries truncate projects beyond picker capacity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const project_names = [_][]const u8{"a"} ** (Projects.PROJECT_COUNT_PICKER_MAX + 1);
    const projects = try test_projects(arena, "/dev/", &project_names);
    const list = from_projects(projects);

    try std.testing.expectEqual(@as(usize, Projects.PROJECT_COUNT_PICKER_MAX), list.len());
}

test "tmux entries put marked sessions first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sessions: Tmux.SessionSet = .empty;
    try sessions.put(arena, "scout", {});
    try sessions.put(arena, "other_project", {});

    const projects = try test_projects(arena, "/home/user/dev/", &.{ "scout", "new", "other.project" });
    const list = try with_active_sessions(arena, projects, sessions);

    try std.testing.expectEqual(@as(usize, 3), list.len());
    try std.testing.expectEqual(@as(usize, 2), list.active_count);
    try std.testing.expectEqualStrings("scout", list.name(0));
    try std.testing.expectEqualStrings("other.project", list.name(1));
    try std.testing.expectEqualStrings("new", list.name(2));
    try std.testing.expectEqual(@as(usize, 2), list.project_index(1));
}

test "tmux entries do not allocate per active label" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sessions: Tmux.SessionSet = .empty;
    try sessions.put(arena, "my_project", {});

    const projects = try test_projects(arena, "/home/user/dev/", &.{"my.project"});
    const list = try with_active_sessions(arena, projects, sessions);

    try std.testing.expectEqual(@as(usize, 1), list.active_count);
    try std.testing.expectEqualStrings("my.project", list.name(0));
}

test "tmux entries truncate projects beyond picker capacity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const names = [_][]const u8{"a"} ** (Projects.PROJECT_COUNT_PICKER_MAX + 1);
    const projects = try test_projects(arena, "/dev/", &names);
    const sessions: Tmux.SessionSet = .empty;

    const list = try with_active_sessions(arena, projects, sessions);
    try std.testing.expectEqual(@as(usize, Projects.PROJECT_COUNT_PICKER_MAX), list.len());
}

fn test_projects(allocator: Allocator, root: []const u8, project_names: []const []const u8) !Projects {
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    var offsets: std.ArrayList(u32) = .empty;
    defer offsets.deinit(allocator);

    try bytes.writer.writeAll(root);
    try offsets.append(allocator, @intCast(bytes.written().len));
    for (project_names) |project_name| {
        try bytes.writer.writeAll(project_name);
        try offsets.append(allocator, @intCast(bytes.written().len));
    }

    return .{
        .bytes = try bytes.toOwnedSlice(),
        .offsets = try offsets.toOwnedSlice(allocator),
        .root_len = @intCast(root.len),
    };
}
