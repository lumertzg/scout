//! Streaming discovery batches for projects under one root directory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Dir = @import("dir.zig");
const Git = @import("git.zig");

/// Maximum number of filesystem entries read and emitted at once.
pub const BATCH_SIZE = 64;
const DIRECTORY_READER_BYTES = 4096;

/// Display and enrichment data for one direct child directory.
pub const Project = struct {
    name: []const u8,
    tmux_session_active: bool = false,
    git_branch: ?[]const u8 = null,
    git_state: Git.State = .{},
};

/// One ordered group of projects emitted during streaming discovery.
pub const Batch = struct {
    /// Zero-based emission order; consumers use it to append batches safely.
    batch_index: usize,
    /// Absolute root path shared by every project in this batch.
    root_path: []const u8,
    /// Structure-of-arrays project storage used by enrichment and rendering.
    projects: std.MultiArrayList(Project),
    /// Set with release ordering after all tmux fields in this batch are ready.
    tmux_enrichment_complete: std.atomic.Value(bool) = .init(false),
    /// Set with release ordering after all Git fields in this batch are ready.
    git_enrichment_complete: std.atomic.Value(bool) = .init(false),
};

/// Emits arena-owned batches of immediate child directory names.
///
/// Calls `emit_context.emit_batch` once per non-empty batch and waits for each
/// call to finish before it reuses the directory reader's entry buffer.
pub fn discover_batches(arena: Allocator, directory: Dir, emit_context: anytype) !void {
    var reader_buffer: [DIRECTORY_READER_BYTES]u8 align(@alignOf(usize)) = undefined;
    var reader = std.Io.Dir.Reader.init(directory.handle, &reader_buffer);

    var entries: [BATCH_SIZE]std.Io.Dir.Entry = undefined;
    var batch_index: usize = 0;

    while (true) {
        const entry_count = try reader.read(directory.io, &entries);
        if (entry_count == 0) {
            if (reader.state == .finished) break;
            continue;
        }

        var project_count: usize = 0;
        var project_names_size_bytes: usize = 0;

        for (entries[0..entry_count]) |entry| {
            if (entry.kind != .directory) continue;
            project_count += 1;
            project_names_size_bytes = try std.math.add(usize, project_names_size_bytes, entry.name.len);
        }

        if (project_count == 0) continue;

        const batch = try arena.create(Batch);
        batch.* = .{
            .batch_index = batch_index,
            .root_path = directory.path,
            .projects = try std.MultiArrayList(Project).initCapacity(arena, project_count),
        };

        const project_names = try arena.alloc(u8, project_names_size_bytes);
        var project_name_offset: usize = 0;
        for (entries[0..entry_count]) |entry| {
            if (entry.kind != .directory) continue;

            const project_name_end = project_name_offset + entry.name.len;
            @memcpy(project_names[project_name_offset..project_name_end], entry.name);

            batch.projects.appendAssumeCapacity(.{
                .name = project_names[project_name_offset..project_name_end],
            });

            project_name_offset = project_name_end;
        }

        assert(project_name_offset == project_names.len);

        try emit_context.emit_batch(batch);
        batch_index += 1;
    }
}

test "streaming discovery emits several stable batches in reader order" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var name_buffer: [32]u8 = undefined;
    for (0..BATCH_SIZE * 2 + 5) |project_index| {
        const project_name = try std.fmt.bufPrint(&name_buffer, "project-{d:0>4}", .{project_index});
        try tmp.dir.createDir(io, project_name, .default_dir);
    }

    const root_path = try test_root_path(arena, tmp.sub_path[0..]);
    var directory = try Dir.open_absolute(arena, io, null, root_path);
    defer directory.close();
    var collector: BatchCollector = .{};
    defer collector.batches.deinit(std.testing.allocator);
    try discover_batches(arena, directory, &collector);

    var entry_count: usize = 0;
    for (collector.batches.items, 0..) |batch, batch_index| {
        try std.testing.expectEqual(batch_index, batch.batch_index);
        try std.testing.expectEqualStrings(directory.path, batch.root_path);
        entry_count += batch.projects.len;
    }
    try std.testing.expect(collector.batches.items.len >= 3);
    try std.testing.expectEqual(@as(usize, BATCH_SIZE * 2 + 5), entry_count);
}

test "streaming discovery emits more than 1024 directories" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var name_buffer: [32]u8 = undefined;
    const project_count = 1025;
    for (0..project_count) |project_index| {
        const project_name = try std.fmt.bufPrint(&name_buffer, "project-{d:0>4}", .{project_index});
        try tmp.dir.createDir(io, project_name, .default_dir);
    }

    const root_path = try test_root_path(arena, tmp.sub_path[0..]);
    var directory = try Dir.open_absolute(arena, io, null, root_path);
    defer directory.close();
    var collector: BatchCollector = .{};
    defer collector.batches.deinit(std.testing.allocator);
    try discover_batches(arena, directory, &collector);

    var emitted_count: usize = 0;
    for (collector.batches.items) |batch| emitted_count += batch.projects.len;
    try std.testing.expectEqual(@as(usize, project_count), emitted_count);
}

test "streaming discovery emits nothing for empty and file-only roots" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root_path = try test_root_path(arena, tmp.sub_path[0..]);

    var collector: BatchCollector = .{};
    defer collector.batches.deinit(std.testing.allocator);
    var empty_directory = try Dir.open_absolute(arena, io, null, root_path);
    try discover_batches(arena, empty_directory, &collector);
    empty_directory.close();
    try std.testing.expectEqual(@as(usize, 0), collector.batches.items.len);

    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "not a project" });
    var file_only_directory = try Dir.open_absolute(arena, io, null, root_path);
    defer file_only_directory.close();
    try discover_batches(arena, file_only_directory, &collector);
    try std.testing.expectEqual(@as(usize, 0), collector.batches.items.len);
}

const BatchCollector = struct {
    batches: std.ArrayList(*Batch) = .empty,

    fn emit_batch(self: *BatchCollector, batch: *Batch) !void {
        try self.batches.append(std.testing.allocator, batch);
    }
};

fn test_root_path(arena: Allocator, sub_path: []const u8) ![]const u8 {
    return std.Io.Dir.path.join(arena, &.{ ".zig-cache", "tmp", sub_path });
}
