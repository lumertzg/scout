//! Picker text-input handling.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const vaxis = @import("vaxis");

const Action = @import("Types.zig").Action;

const PROJECT_NAME_BYTES_MAX = std.Io.Dir.max_name_bytes;

/// Applies a key while entries are still loading.
pub fn handle_loading_key(query: *std.ArrayList(u8), allocator: Allocator, key: vaxis.Key) !Action {
    if (key.matches(vaxis.Key.escape, .{}) or key.matches('c', .{ .ctrl = true })) {
        return .cancel;
    }

    if (key.matches(vaxis.Key.backspace, .{})) {
        if (query.items.len == 0) return .ignore;
        remove_last_codepoint(query);
        return .redraw;
    }

    const text = key.text orelse return .ignore;
    if (!accepts_text(key.mods, text)) return .ignore;
    assert(query.items.len <= PROJECT_NAME_BYTES_MAX);
    if (text.len > PROJECT_NAME_BYTES_MAX - query.items.len) return .ignore;

    try query.appendSlice(allocator, text);
    return .redraw;
}

/// Returns whether a key's text may be appended to the search query.
pub fn accepts_text(mods: vaxis.Key.Modifiers, text: []const u8) bool {
    if (mods.ctrl or mods.alt or mods.super or mods.hyper or mods.meta) return false;
    return text.len > 0 and text[0] >= ' ' and text[0] != 0x7f;
}

/// Removes the last complete UTF-8 codepoint, tolerating invalid trailing data.
pub fn remove_last_codepoint(query: *std.ArrayList(u8)) void {
    if (query.items.len == 0) return;

    var new_len = query.items.len - 1;

    while (new_len > 0 and query.items[new_len] & 0xc0 == 0x80) {
        new_len -= 1;
    }

    query.items.len = new_len;
}

/// Finds the longest UTF-8 prefix no longer than `byte_limit` bytes.
pub fn valid_prefix_len(text: []const u8, byte_limit: usize) usize {
    var prefix_len = @min(text.len, byte_limit);
    if (prefix_len == text.len) return prefix_len;

    while (prefix_len > 0 and text[prefix_len] & 0xc0 == 0x80) {
        prefix_len -= 1;
    }
    return prefix_len;
}
