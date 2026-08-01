//! Tests for picker UI components.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const vaxis = @import("vaxis");

const Entries = @import("../Entries.zig");
const Input = @import("Input.zig");
const Projects = @import("../../Projects.zig");
const Renderer = @import("Renderer.zig");
const StateModule = @import("State.zig");
const State = StateModule.State;
const PendingFilter = StateModule.PendingFilter;
const ViewState = @import("ViewState.zig").ViewState;
const Action = @import("Types.zig").Action;
const Layout = Renderer.Layout;

const handle_loading_key = Input.handle_loading_key;
const remove_last_codepoint = Input.remove_last_codepoint;
const valid_prefix_len = Input.valid_prefix_len;

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
    try view_state.append_batch(std.testing.allocator, entries.batches[0]);

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
    try std.testing.expect(state.move_up());
    try std.testing.expectEqualStrings("scout", state.selected_item().?);
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
    try std.testing.expectEqualStrings("source", state.entries.entry_name(state.matches.items[0].entry_index));
    try std.testing.expectEqualStrings("scout", state.entries.entry_name(state.matches.items[1].entry_index));

    remove_last_codepoint(&state.query);
    remove_last_codepoint(&state.folded_query);
    state.refresh_matches();
    try std.testing.expectEqual(@as(usize, 3), state.match_count);
    try std.testing.expectEqualStrings("rust", state.entries.entry_name(state.matches.items[2].entry_index));
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

test "git metadata is shown only for the selected entry" {
    try std.testing.expect(Renderer.should_draw_git_metadata(true));
    try std.testing.expect(!Renderer.should_draw_git_metadata(false));
}

test "ranked matches use platform-sized entry indices" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(State.RankedMatch));
}

test "picker accepts more than 1024 projects" {
    const project_count = 1025;
    const names = [_][]const u8{"a"} ** project_count;
    const entries = try test_entries(std.testing.allocator, &names, 0);
    defer deinit_test_entries(entries);

    var state = try State.init(std.testing.allocator, entries);
    defer state.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, project_count), state.match_count);
    try state.append_query(std.testing.allocator, "a");
    state.refresh_matches();
    try std.testing.expectEqual(@as(usize, project_count), state.match_count);
}

test "streamed state survives batch pointer growth and selects a later batch" {
    const names = [_][]const u8{"a"} ** (Projects.BATCH_SIZE * Projects.BATCH_SIZE) ++ [_][]const u8{"later-project"};
    const entries = try test_entries(std.testing.allocator, &names, 0);
    defer deinit_test_entries(entries);
    var view_state = try ViewState.init(std.testing.allocator);
    defer view_state.deinit(std.testing.allocator);

    for (entries.batches) |batch| try view_state.append_batch(std.testing.allocator, batch);
    const ready = &view_state.ready.?;
    try ready.append_query(std.testing.allocator, "later");
    ready.refresh_matches();

    try std.testing.expectEqual(@as(usize, names.len), view_state.entry_count);
    try std.testing.expectEqual(@as(usize, 1), ready.match_count);
    try std.testing.expectEqualStrings("later-project", view_state.selection().?.project_name);
}

test "later batches widen accepted input and preserve query and selection" {
    const names = [_][]const u8{"a"} ** Projects.BATCH_SIZE ++ [_][]const u8{"alphabet"};
    const entries = try test_entries(std.testing.allocator, &names, 0);
    defer deinit_test_entries(entries);
    const first_batch_entries: Entries.List = .{
        .batches = entries.batches[0..1],
        .locations = entries.locations[0..Projects.BATCH_SIZE],
    };
    var state = try State.init(std.testing.allocator, first_batch_entries);
    defer state.deinit(std.testing.allocator);

    try state.append_query(std.testing.allocator, "a");
    state.refresh_matches();
    state.selected_index = 10;
    const selected_entry_location = state.selected_location().?;
    try state.append_entries(
        std.testing.allocator,
        entries,
        first_batch_entries.len(),
    );

    try std.testing.expectEqualStrings("a", state.query.items);
    try std.testing.expectEqual(@as(usize, "alphabet".len), state.project_name_size_bytes_max);
    try std.testing.expectEqual(@as(usize, names.len), state.match_count);
    const restored_entry_location = state.selected_location().?;
    try std.testing.expect(restored_entry_location.batch == selected_entry_location.batch);
    try std.testing.expectEqual(restored_entry_location.name_index, selected_entry_location.name_index);
}

test "published active entries keep the initial selection next to the input" {
    const names = [_][]const u8{ "inactive", "active" };
    const entries = try test_entries(std.testing.allocator, &names, 0);
    defer deinit_test_entries(entries);
    var state = try State.init(std.testing.allocator, entries);
    defer state.deinit(std.testing.allocator);

    const batch = entries.batches[0];
    batch.projects.slice().items(.tmux_session_active)[1] = true;
    batch.tmux_enrichment_complete.store(true, .release);
    state.sort_matches_preserving_selection();

    try std.testing.expectEqual(@as(usize, 1), state.matches.items[0].entry_index);
    try std.testing.expectEqual(@as(usize, 0), state.selected_index);
    const layout: Layout = .init(24);
    try std.testing.expectEqual(@as(u16, 20), layout.item_row(state.selected_index));
    try std.testing.expectEqual(@as(usize, 1), state.selected_location().?.name_index);
}

test "published active entries preserve a moved selection" {
    const names = [_][]const u8{ "first", "selected", "active" };
    const entries = try test_entries(std.testing.allocator, &names, 0);
    defer deinit_test_entries(entries);
    var state = try State.init(std.testing.allocator, entries);
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(state.move_up());
    const selected_entry_location = state.selected_location().?;
    const batch = entries.batches[0];
    batch.projects.slice().items(.tmux_session_active)[2] = true;
    batch.tmux_enrichment_complete.store(true, .release);
    state.sort_matches_preserving_selection();

    try std.testing.expectEqual(@as(usize, 2), state.matches.items[0].entry_index);
    const restored_entry_location = state.selected_location().?;
    try std.testing.expect(restored_entry_location.batch == selected_entry_location.batch);
    try std.testing.expectEqual(restored_entry_location.name_index, selected_entry_location.name_index);
}

test "clearing a query restores enriched empty-query order" {
    const names = [_][]const u8{ "same", "same" };
    const entries = try test_entries(std.testing.allocator, &names, 0);
    defer deinit_test_entries(entries);
    var state = try State.init(std.testing.allocator, entries);
    defer state.deinit(std.testing.allocator);

    const batch = entries.batches[0];
    batch.projects.slice().items(.tmux_session_active)[1] = true;
    batch.tmux_enrichment_complete.store(true, .release);
    state.sort_matches_preserving_selection();
    try std.testing.expectEqual(@as(usize, 1), state.matches.items[0].entry_index);

    try state.append_query(std.testing.allocator, "s");
    state.narrow_matches();
    remove_last_codepoint(&state.query);
    remove_last_codepoint(&state.folded_query);
    state.refresh_matches();

    try std.testing.expectEqual(@as(usize, 1), state.matches.items[0].entry_index);
    try std.testing.expectEqual(@as(usize, 0), state.matches.items[1].entry_index);
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
    const batch_count = std.math.divCeil(usize, project_names.len, Projects.BATCH_SIZE) catch unreachable;
    const batches = try allocator.alloc(*Projects.Batch, batch_count);
    errdefer allocator.free(batches);
    const locations = try allocator.alloc(Entries.EntryLocation, project_names.len);
    errdefer allocator.free(locations);

    var initialized_batch_count: usize = 0;
    errdefer for (batches[0..initialized_batch_count]) |batch| {
        batch.projects.deinit(allocator);
        allocator.destroy(batch);
    };
    for (batches, 0..) |*batch_pointer, batch_index| {
        const name_start = batch_index * Projects.BATCH_SIZE;
        const names = project_names[name_start..@min(name_start + Projects.BATCH_SIZE, project_names.len)];
        const batch = try allocator.create(Projects.Batch);
        batch.* = .{
            .batch_index = batch_index,
            .root_path = "/dev/",
            .projects = try std.MultiArrayList(Projects.Project).initCapacity(allocator, Projects.BATCH_SIZE),
        };
        for (names, name_start..) |name, entry_index| {
            batch.projects.appendAssumeCapacity(.{
                .name = name,
                .tmux_session_active = entry_index < active_count,
            });
            locations[entry_index] = .{
                .batch = batch,
                .name_index = entry_index - name_start,
            };
        }
        if (active_count > name_start) batch.tmux_enrichment_complete.store(true, .release);
        batch_pointer.* = batch;
        initialized_batch_count += 1;
    }
    return .{
        .batches = batches,
        .locations = locations,
    };
}

fn deinit_test_entries(entries: Entries.List) void {
    for (entries.batches) |batch| {
        batch.projects.deinit(std.testing.allocator);
        std.testing.allocator.destroy(batch);
    }
    std.testing.allocator.free(entries.batches);
    std.testing.allocator.free(entries.locations);
}
