//! Isolates libgit2 repository inspection.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const c = @cImport({
    @cInclude("git2.h");
});

/// Repository status flags used by the picker.
///
/// The packed layout keeps each project record small. Padding reserves bits
/// without exposing them as status.
pub const State = packed struct(u16) {
    conflicted: bool = false,
    stashed: bool = false,
    deleted: bool = false,
    renamed: bool = false,
    modified: bool = false,
    staged: bool = false,
    untracked: bool = false,
    ahead: bool = false,
    behind: bool = false,
    _padding: u7 = 0,

    pub fn is_empty(self: State) bool {
        return @as(u16, @bitCast(self)) == 0;
    }
};

/// Git metadata shown for a discovered project.
pub const Info = struct {
    /// Arena-owned branch name, or null when HEAD cannot name one.
    branch: ?[]const u8 = null,
    state: State = .{},
};

/// Initializes libgit2 for repository inspection.
pub fn init() !Self {
    if (c.git_libgit2_init() < 0) return error.GitInitializationFailed;
    return .{};
}

pub fn deinit(_: *Self) void {
    const remaining_initializations = c.git_libgit2_shutdown();
    assert(remaining_initializations >= 0);
}

/// Inspects a direct child project without discovering repositories above it.
pub fn inspect(_: Self, allocator: Allocator, root_path: []const u8, project_name: []const u8) !?Info {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_size = try std.math.add(usize, root_path.len, project_name.len);
    if (path_size >= path_buffer.len) return error.NameTooLong;

    @memcpy(path_buffer[0..root_path.len], root_path);
    @memcpy(path_buffer[root_path.len..path_size], project_name);

    path_buffer[path_size] = 0;
    const path: [*:0]const u8 = @ptrCast(&path_buffer);

    var repository: ?*c.git_repository = null;
    const open_result = c.git_repository_open_ext(
        &repository,
        path,
        c.GIT_REPOSITORY_OPEN_NO_SEARCH,
        null,
    );

    if (open_result == c.GIT_ENOTFOUND) return null;

    try check(open_result);
    defer c.git_repository_free(repository.?);

    var info: Info = .{};
    try read_head(allocator, repository.?, &info);
    try read_status(repository.?, &info.state);
    try read_stash(repository.?, &info.state);

    return info;
}

fn read_head(allocator: Allocator, repository: *c.git_repository, info: *Info) !void {
    var head: ?*c.git_reference = null;
    const head_result = c.git_repository_head(&head, repository);

    if (head_result == c.GIT_EUNBORNBRANCH) {
        try read_unborn_branch(allocator, repository, info);
        return;
    }

    if (head_result == c.GIT_ENOTFOUND) return;
    try check(head_result);
    defer c.git_reference_free(head.?);

    var branch_name: [*c]const u8 = null;

    const branch_result = c.git_branch_name(&branch_name, head.?);
    if (branch_result == 0) {
        info.branch = try allocator.dupe(u8, std.mem.span(branch_name));
    } else if (try head_is_detached(repository)) {
        const oid = c.git_reference_target(head.?) orelse return;
        const oid_text = std.mem.span(c.git_oid_tostr_s(oid));
        info.branch = try allocator.dupe(u8, oid_text[0..@min(oid_text.len, 7)]);
        return;
    } else {
        try check(branch_result);
    }

    var upstream: ?*c.git_reference = null;
    const upstream_result = c.git_branch_upstream(&upstream, head.?);
    if (upstream_result == c.GIT_ENOTFOUND) return;
    try check(upstream_result);
    defer c.git_reference_free(upstream.?);

    const local_oid = c.git_reference_target(head.?) orelse return;
    const upstream_oid = c.git_reference_target(upstream.?) orelse return;

    var ahead_count: usize = 0;
    var behind_count: usize = 0;
    try check(c.git_graph_ahead_behind(&ahead_count, &behind_count, repository, local_oid, upstream_oid));

    info.state.ahead = ahead_count > 0;
    info.state.behind = behind_count > 0;
}

fn head_is_detached(repository: *c.git_repository) !bool {
    const result = c.git_repository_head_detached(repository);
    try check(result);
    return result == 1;
}

fn read_unborn_branch(allocator: Allocator, repository: *c.git_repository, info: *Info) !void {
    var head: ?*c.git_reference = null;
    try check(c.git_reference_lookup(&head, repository, "HEAD"));
    defer c.git_reference_free(head.?);

    const target = c.git_reference_symbolic_target(head.?) orelse return;
    const qualified_name = std.mem.span(target);
    const prefix = "refs/heads/";
    const branch_name = if (std.mem.startsWith(u8, qualified_name, prefix)) qualified_name[prefix.len..] else qualified_name;
    info.branch = try allocator.dupe(u8, branch_name);
}

fn read_status(repository: *c.git_repository, state: *State) !void {
    var options: c.git_status_options = undefined;
    try check(c.git_status_options_init(&options, c.GIT_STATUS_OPTIONS_VERSION));

    options.flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED |
        c.GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX |
        c.GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR;

    var status_list: ?*c.git_status_list = null;
    try check(c.git_status_list_new(&status_list, repository, &options));
    defer c.git_status_list_free(status_list.?);

    for (0..c.git_status_list_entrycount(status_list.?)) |status_index| {
        const entry = c.git_status_byindex(status_list.?, status_index) orelse continue;
        const flags = entry.*.status;

        state.conflicted = state.conflicted or has(flags, c.GIT_STATUS_CONFLICTED);
        state.deleted = state.deleted or has(flags, c.GIT_STATUS_INDEX_DELETED) or has(flags, c.GIT_STATUS_WT_DELETED);
        state.renamed = state.renamed or has(flags, c.GIT_STATUS_INDEX_RENAMED) or has(flags, c.GIT_STATUS_WT_RENAMED);
        state.modified = state.modified or has(flags, c.GIT_STATUS_WT_MODIFIED) or has(flags, c.GIT_STATUS_WT_TYPECHANGE) or has(flags, c.GIT_STATUS_WT_UNREADABLE);
        state.staged = state.staged or has(flags, c.GIT_STATUS_INDEX_NEW) or has(flags, c.GIT_STATUS_INDEX_MODIFIED) or has(flags, c.GIT_STATUS_INDEX_TYPECHANGE);
        state.untracked = state.untracked or has(flags, c.GIT_STATUS_WT_NEW);
    }
}

fn read_stash(repository: *c.git_repository, state: *State) !void {
    var stash: ?*c.git_reference = null;
    const result = c.git_reference_lookup(&stash, repository, "refs/stash");
    if (result == c.GIT_ENOTFOUND) return;
    try check(result);

    c.git_reference_free(stash.?);
    state.stashed = true;
}

fn has(flags: c.git_status_t, expected: c.git_status_t) bool {
    return flags & expected != 0;
}

fn check(result: c_int) !void {
    if (result < 0) return error.GitOperationFailed;
}

test "git state remains two bytes" {
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(State));
}

test "inspect reports branch and status for attached and detached repositories" {
    var git: Self = try .init();
    defer git.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "repo", .default_dir);
    try tmp.dir.createDir(std.testing.io, "plain", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/untracked.txt", .data = "new" });

    const root_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/", .{tmp.sub_path});
    defer std.testing.allocator.free(root_path);
    const repository_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}repo", .{root_path}, 0);
    defer std.testing.allocator.free(repository_path);

    var repository: ?*c.git_repository = null;
    try check(c.git_repository_init(&repository, repository_path, 0));
    c.git_repository_free(repository.?);

    const info = (try git.inspect(std.testing.allocator, root_path, "repo")).?;
    defer if (info.branch) |branch| std.testing.allocator.free(branch);
    try std.testing.expect(info.branch != null);
    try std.testing.expect(info.state.untracked);
    try std.testing.expect(!(try git.inspect(std.testing.allocator, root_path, "plain") != null));

    try detach_head(repository_path);
    const detached_info = (try git.inspect(std.testing.allocator, root_path, "repo")).?;
    defer if (detached_info.branch) |branch| std.testing.allocator.free(branch);
    try std.testing.expectEqual(@as(usize, 7), detached_info.branch.?.len);
    try std.testing.expect(detached_info.state.untracked);
}

fn detach_head(repository_path: [:0]const u8) !void {
    var repository: ?*c.git_repository = null;
    try check(c.git_repository_open(&repository, repository_path));
    defer c.git_repository_free(repository.?);

    var index: ?*c.git_index = null;
    try check(c.git_repository_index(&index, repository.?));
    defer c.git_index_free(index.?);

    var tree_oid: c.git_oid = undefined;
    try check(c.git_index_write_tree(&tree_oid, index.?));
    var tree: ?*c.git_tree = null;
    try check(c.git_tree_lookup(&tree, repository.?, &tree_oid));
    defer c.git_tree_free(tree.?);

    var signature: ?*c.git_signature = null;
    try check(c.git_signature_now(&signature, "Scout Test", "scout@example.com"));
    defer c.git_signature_free(signature.?);

    var commit_oid: c.git_oid = undefined;
    try check(c.git_commit_create(
        &commit_oid,
        repository.?,
        "HEAD",
        signature.?,
        signature.?,
        null,
        "initial",
        tree.?,
        0,
        null,
    ));
    try check(c.git_repository_set_head_detached(repository.?, &commit_oid));
}
