//! Streaming discovery batches for projects under one root directory.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Dir = @import("dir.zig");

pub const BATCH_SIZE = 64;
const DIRECTORY_READER_BYTES = 4096;

/// Immutable, arena-owned project names from one directory read.
pub const Batch = struct {
    root_path: []const u8,
    names: []const []const u8,
};

/// Emits immediate child directories in filesystem discovery order.
pub fn discover_batches(arena: Allocator, directory: Dir, emit_context: anytype) !void {
    var reader_buffer: [DIRECTORY_READER_BYTES]u8 align(@alignOf(usize)) = undefined;
    var reader = std.Io.Dir.Reader.init(directory.handle, &reader_buffer);
    var entries: [BATCH_SIZE]std.Io.Dir.Entry = undefined;

    while (true) {
        const entry_count = try reader.read(directory.io, &entries);
        if (entry_count == 0) {
            if (reader.state == .finished) break;
            continue;
        }

        var accepted: [BATCH_SIZE][]const u8 = undefined;
        var accepted_count: usize = 0;
        var byte_count: usize = 0;

        for (entries[0..entry_count]) |entry| {
            if (!std.unicode.utf8ValidateSlice(entry.name)) continue;
            if (!is_project(directory, entry)) continue;

            accepted[accepted_count] = entry.name;
            accepted_count += 1;

            byte_count = try std.math.add(usize, byte_count, entry.name.len);
        }

        if (accepted_count == 0) continue;

        const names = try arena.alloc([]const u8, accepted_count);
        const bytes = try arena.alloc(u8, byte_count);
        var offset: usize = 0;

        for (accepted[0..accepted_count], names) |name, *owned_name| {
            @memcpy(bytes[offset..][0..name.len], name);
            owned_name.* = bytes[offset..][0..name.len];
            offset += name.len;
        }

        const batch = try arena.create(Batch);
        batch.* = .{
            .root_path = directory.path,
            .names = names,
        };

        try emit_context.emit_batch(batch);
    }
}

fn is_project(directory: Dir, entry: std.Io.Dir.Entry) bool {
    if (entry.kind == .directory) return true;
    if (entry.kind != .sym_link) return false;

    const target = directory.handle.statFile(directory.io, entry.name, .{}) catch return false;
    return target.kind == .directory;
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

test "discovery includes hidden directories and directory symlinks" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, ".hidden", .default_dir);
    try tmp.dir.createDir(io, "target", .default_dir);
    try tmp.dir.symLink(io, "target", "link", .{});
    try tmp.dir.symLink(io, "missing", "broken", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "x" });
    try tmp.dir.symLink(io, "file", "file-link", .{});
    if (@import("builtin").os.tag != .windows) {
        try tmp.dir.createDir(io, &.{0xff}, .default_dir);
    }

    var restricted_target: ?std.Io.Dir = null;
    if (@import("builtin").os.tag != .windows) {
        restricted_target = try tmp.dir.openDir(io, "target", .{ .iterate = true });
        try restricted_target.?.setPermissions(io, .fromMode(0));
    }
    defer if (restricted_target) |target| {
        target.setPermissions(io, .fromMode(0o700)) catch {};
        target.close(io);
    };

    const root = try test_root_path(arena, tmp.sub_path[0..]);
    var directory = try Dir.open_absolute(arena, io, null, root);
    defer directory.close();
    var collector: BatchCollector = .{};
    defer collector.batches.deinit(std.testing.allocator);
    try discover_batches(arena, directory, &collector);

    var found_hidden = false;
    var found_link = false;
    var found_broken = false;
    var found_invalid = false;
    var found_file_link = false;
    for (collector.batches.items) |batch| {
        for (batch.names) |name| {
            found_hidden = found_hidden or std.mem.eql(u8, name, ".hidden");
            found_link = found_link or std.mem.eql(u8, name, "link");
            found_broken = found_broken or std.mem.eql(u8, name, "broken");
            found_invalid = found_invalid or std.mem.eql(u8, name, &.{0xff});
            found_file_link = found_file_link or std.mem.eql(u8, name, "file-link");
        }
    }
    try std.testing.expect(found_hidden);
    try std.testing.expect(found_link);
    try std.testing.expect(!found_broken);
    try std.testing.expect(!found_invalid);
    try std.testing.expect(!found_file_link);
}

test "discovery streams several batches and has no project limit" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buffer: [32]u8 = undefined;
    for (0..1025) |index| {
        const name = try std.fmt.bufPrint(&buffer, "project-{d:0>4}", .{index});
        try tmp.dir.createDir(io, name, .default_dir);
    }
    const root = try test_root_path(arena, tmp.sub_path[0..]);

    var expected: std.ArrayList([]const u8) = .empty;
    var expected_directory = try Dir.open_absolute(arena, io, null, root);
    var reader_buffer: [DIRECTORY_READER_BYTES]u8 align(@alignOf(usize)) = undefined;
    var reader = std.Io.Dir.Reader.init(expected_directory.handle, &reader_buffer);
    var raw_entries: [BATCH_SIZE]std.Io.Dir.Entry = undefined;
    while (true) {
        const count = try reader.read(io, &raw_entries);
        if (count == 0) {
            if (reader.state == .finished) break;
            continue;
        }
        for (raw_entries[0..count]) |entry| {
            try expected.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    expected_directory.close();

    var directory = try Dir.open_absolute(arena, io, null, root);
    defer directory.close();
    var collector: BatchCollector = .{};
    defer collector.batches.deinit(std.testing.allocator);
    try discover_batches(arena, directory, &collector);
    var count: usize = 0;
    for (collector.batches.items) |batch| {
        for (batch.names) |name| {
            try std.testing.expectEqualStrings(expected.items[count], name);
            count += 1;
        }
    }
    try std.testing.expect(collector.batches.items.len > 1);
    try std.testing.expectEqual(@as(usize, 1025), count);
}
