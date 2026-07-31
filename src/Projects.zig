//! Compact snapshot of projects under one root directory.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Dir = @import("dir.zig");

pub const PROJECT_COUNT_PICKER_MAX = 1024;

const DIRECTORY_ENTRY_COUNT_PER_BATCH = 64;
const DIRECTORY_READER_BYTES = 4096;
const PROJECT_NAME_BYTES_EXPECTED_AVERAGE = 32;
const PROJECT_NAMES_BYTES_EXPECTED = PROJECT_COUNT_PICKER_MAX * PROJECT_NAME_BYTES_EXPECTED_AVERAGE;

bytes: []const u8,
offsets: []const u32,
root_len: u32,

/// Stores the immediate child names from an open directory.
pub fn init(arena: Allocator, directory: Dir) !Self {
    var bytes = try std.Io.Writer.Allocating.initCapacity(arena, PROJECT_NAMES_BYTES_EXPECTED);

    try bytes.writer.writeAll(directory.path);

    const root_len = std.math.cast(u32, bytes.written().len) orelse return error.ListTooLarge;

    var offsets = try std.ArrayList(u32).initCapacity(arena, PROJECT_COUNT_PICKER_MAX + 1);

    try offsets.append(arena, root_len);

    var reader_buffer: [DIRECTORY_READER_BYTES]u8 align(@alignOf(usize)) = undefined;
    var reader = std.Io.Dir.Reader.init(directory.handle, &reader_buffer);
    var entries: [DIRECTORY_ENTRY_COUNT_PER_BATCH]std.Io.Dir.Entry = undefined;

    while (true) {
        const count = try reader.read(directory.io, &entries);
        if (count == 0) {
            if (reader.state == .finished) break;
            continue;
        }

        for (entries[0..count]) |entry| {
            if (entry.kind != .directory) continue;

            try bytes.writer.writeAll(entry.name);
            const end = std.math.cast(u32, bytes.written().len) orelse return error.ListTooLarge;
            try offsets.append(arena, end);
        }
    }

    assert(offsets.items.len > 0);
    assert(offsets.items[offsets.items.len - 1] == bytes.written().len);
    assert(root_len <= bytes.written().len);

    // Arena ownership avoids shrink-to-fit copies after discovery.
    return .{
        .bytes = bytes.written(),
        .offsets = offsets.items,
        .root_len = root_len,
    };
}

pub inline fn len(self: Self) usize {
    assert(self.offsets.len > 0);
    return self.offsets.len - 1;
}

pub inline fn root(self: Self) []const u8 {
    assert(self.root_len <= self.bytes.len);
    return self.bytes[0..self.root_len];
}

pub inline fn name(self: Self, project_index: usize) []const u8 {
    assert(project_index < self.len());
    const start = self.offsets[project_index];
    const end = self.offsets[project_index + 1];
    assert(start <= end);
    assert(end <= self.bytes.len);
    return self.bytes[start..end];
}

/// Allocates the absolute path only after a project has been selected.
pub fn alloc_path(self: Self, arena: Allocator, project_index: usize) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ self.root(), self.name(project_index) });
}

/// Writes project names without constructing their absolute paths.
pub fn write_names(self: Self, writer: *std.Io.Writer) !void {
    for (0..self.len()) |project_index| {
        try writer.writeAll(self.name(project_index));
        try writer.writeByte('\n');
    }
}

test "stores the absolute root followed by immediate project names" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "alpha/nested");
    try tmp.dir.createDir(io, "beta", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "" });

    const root_path = try std.Io.Dir.path.join(arena, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
    });
    var directory = try Dir.open_absolute(arena, io, null, root_path);
    defer directory.close();
    const projects: Self = try .init(arena, directory);

    try std.testing.expect(std.Io.Dir.path.isAbsolute(projects.root()));
    try std.testing.expect(std.Io.Dir.path.isSep(projects.root()[projects.root().len - 1]));
    try std.testing.expectEqual(@as(usize, 2), projects.len());
    try std.testing.expectEqual(@as(u32, @intCast(projects.bytes.len)), projects.offsets[projects.offsets.len - 1]);

    var found_alpha = false;
    var found_beta = false;
    for (0..projects.len()) |project_index| {
        const project_name = projects.name(project_index);
        found_alpha = found_alpha or std.mem.eql(u8, project_name, "alpha");
        found_beta = found_beta or std.mem.eql(u8, project_name, "beta");
        try std.testing.expect(!std.mem.eql(u8, project_name, "nested"));
        try std.testing.expect(!std.mem.eql(u8, project_name, "file.txt"));
    }
    try std.testing.expect(found_alpha);
    try std.testing.expect(found_beta);
}

test "builds a selected path only on demand" {
    const projects: Self = .{
        .bytes = "/home/user/dev/scoutother",
        .offsets = &.{ 15, 20, 25 },
        .root_len = 15,
    };
    const selected_path = try projects.alloc_path(std.testing.allocator, 1);
    defer std.testing.allocator.free(selected_path);
    try std.testing.expectEqualStrings("/home/user/dev/other", selected_path);
}

test "writes only project names" {
    const projects: Self = .{
        .bytes = "/dev/alphaother",
        .offsets = &.{ 5, 10, 15 },
        .root_len = 5,
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try projects.write_names(&output.writer);
    try std.testing.expectEqualStrings("alpha\nother\n", output.written());
}
