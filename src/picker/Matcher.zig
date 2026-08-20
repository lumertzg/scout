//! Path-aware fuzzy matching for picker entries.

const std = @import("std");
const assert = std.debug.assert;

const SCORE_MATCH = 16;
const BONUS_CONSECUTIVE = 24;
const BONUS_BOUNDARY_START = 32;
const BONUS_PATH_SEPARATOR = 30;
const BONUS_WHITESPACE = 26;
const BONUS_DELIMITER = 20;
const BONUS_CAMEL_CASE = 18;
const GAP_PENALTY_MAX = 16;
const LEADING_PENALTY_MAX = 16;

const AlignmentOptions = struct {
    query_is_folded: bool = false,
    collect_positions: bool = false,
};

const BOUNDARY_BONUSES: [256]u8 = blk: {
    var bonuses = [_]u8{0} ** 256;

    for (0..bonuses.len) |value| {
        const byte: u8 = @intCast(value);
        if (std.ascii.isWhitespace(byte)) bonuses[value] = BONUS_WHITESPACE;
    }

    bonuses['/'] = BONUS_PATH_SEPARATOR;
    bonuses['\\'] = BONUS_PATH_SEPARATOR;
    for ([_]u8{ '_', '-', '.', ':', ';', ',', '|' }) |byte| {
        bonuses[byte] = BONUS_DELIMITER;
    }

    break :blk bonuses;
};

/// Score and byte range for the chosen fuzzy-match alignment.
pub const Result = struct {
    score: i32,
    /// Inclusive start and exclusive end byte offsets.
    start: usize,
    end: usize,
};

/// Scores a project name while favoring compact matches.
pub fn rank(query: []const u8, candidate: []const u8) ?Result {
    return find_alignment(.{}, query, query, candidate, 0, candidate.len, {});
}

/// Returns whether query characters occur in order within candidate.
pub fn matches(query: []const u8, candidate: []const u8) bool {
    if (query.len == 0) return true;
    return find_forward_end(false, query, candidate, 0, candidate.len) != null;
}

/// Scores with a query folded to lowercase ASCII.
pub fn rank_folded(query: []const u8, folded_query: []const u8, candidate: []const u8) ?Result {
    assert(query.len == folded_query.len);
    return find_alignment(
        .{ .query_is_folded = true },
        query,
        folded_query,
        candidate,
        0,
        candidate.len,
        {},
    );
}

/// Scores and writes the byte positions used by the selected alignment.
pub fn rank_folded_positions(
    query: []const u8,
    folded_query: []const u8,
    candidate: []const u8,
    output: []u16,
) ?Result {
    assert(query.len == folded_query.len);
    assert(output.len >= query.len);
    assert(candidate.len <= std.math.maxInt(u16));
    return find_alignment(
        .{ .query_is_folded = true, .collect_positions = true },
        query,
        folded_query,
        candidate,
        0,
        candidate.len,
        output,
    );
}

/// Writes the byte positions used by the highest-ranked alignment.
pub fn positions(query: []const u8, candidate: []const u8, output: []u16) ?[]const u16 {
    assert(output.len >= query.len);
    assert(candidate.len <= std.math.maxInt(u16));
    _ = find_alignment(
        .{ .collect_positions = true },
        query,
        query,
        candidate,
        0,
        candidate.len,
        output,
    ) orelse return null;
    return output[0..query.len];
}

/// Writes positions using a folded query.
pub fn positions_folded(
    query: []const u8,
    folded_query: []const u8,
    candidate: []const u8,
    output: []u16,
) ?[]const u16 {
    _ = rank_folded_positions(query, folded_query, candidate, output) orelse return null;
    return output[0..query.len];
}

fn find_alignment(
    comptime options: AlignmentOptions,
    query: []const u8,
    match_query: []const u8,
    candidate: []const u8,
    window_start: usize,
    window_end: usize,
    positions_output: if (options.collect_positions) []u16 else void,
) ?Result {
    assert(query.len == match_query.len);
    assert(window_start <= window_end);
    assert(window_end <= candidate.len);
    if (query.len == 0) return .{ .score = 0, .start = 0, .end = 0 };
    if (query.len > window_end - window_start) return null;

    if (score_prefix_alignment(
        options,
        query,
        match_query,
        candidate,
        window_start,
        window_end,
        positions_output,
    )) |prefix| return prefix;

    // Find the earliest complete match, then walk backward from its end to
    // tighten the alignment before scoring it.
    const forward_end = find_forward_end(
        options.query_is_folded,
        match_query,
        candidate,
        window_start,
        window_end,
    ) orelse return null;

    const start = find_backward_start(
        options.query_is_folded,
        match_query,
        candidate,
        window_start,
        forward_end,
    );

    var query_index: usize = 0;
    var previous_match: ?usize = null;
    var score: i32 = 0;
    var end = start;

    for (start..forward_end) |candidate_index| {
        if (!equal_fold(options.query_is_folded, candidate[candidate_index], match_query[query_index])) continue;

        if (comptime options.collect_positions) {
            positions_output[query_index] = @intCast(candidate_index);
        }

        score += SCORE_MATCH + boundary_bonus(candidate, candidate_index);
        if (candidate[candidate_index] == query[query_index]) score += 1;

        if (previous_match) |previous| {
            if (candidate_index == previous + 1) {
                score += BONUS_CONSECUTIVE;
            } else {
                const gap = candidate_index - previous - 1;
                score -= @intCast(@min(gap, GAP_PENALTY_MAX));
            }
        }

        previous_match = candidate_index;
        end = candidate_index + 1;
        query_index += 1;

        if (query_index == query.len) break;
    }

    score -= @intCast(@min(start - window_start, LEADING_PENALTY_MAX));
    return .{ .score = score, .start = start, .end = end };
}

inline fn score_prefix_alignment(
    comptime options: AlignmentOptions,
    query: []const u8,
    match_query: []const u8,
    candidate: []const u8,
    window_start: usize,
    window_end: usize,
    positions_output: if (options.collect_positions) []u16 else void,
) ?Result {
    if (query.len > window_end - window_start) return null;

    var score: i32 = 0;
    for (0..query.len) |query_index| {
        const candidate_byte = candidate[window_start + query_index];
        const query_byte = match_query[query_index];
        if (!equal_fold(options.query_is_folded, candidate_byte, query_byte)) return null;

        if (comptime options.collect_positions) {
            positions_output[query_index] = @intCast(window_start + query_index);
        }

        score += SCORE_MATCH + boundary_bonus(candidate, window_start + query_index);
        if (candidate_byte == query[query_index]) score += 1;
        if (query_index > 0) score += BONUS_CONSECUTIVE;
    }

    return .{ .score = score, .start = window_start, .end = window_start + query.len };
}

fn find_forward_end(
    comptime query_is_folded: bool,
    match_query: []const u8,
    candidate: []const u8,
    window_start: usize,
    window_end: usize,
) ?usize {
    var query_index: usize = 0;
    for (window_start..window_end) |candidate_index| {
        if (!equal_fold(query_is_folded, candidate[candidate_index], match_query[query_index])) continue;

        query_index += 1;
        if (query_index == match_query.len) return candidate_index + 1;
    }
    return null;
}

fn find_backward_start(
    comptime query_is_folded: bool,
    match_query: []const u8,
    candidate: []const u8,
    window_start: usize,
    forward_end: usize,
) usize {
    assert(match_query.len > 0);
    assert(window_start < forward_end);
    assert(forward_end <= candidate.len);

    var query_index = match_query.len;
    var candidate_index = forward_end;

    while (query_index > 0) {
        candidate_index -= 1;

        if (!equal_fold(query_is_folded, candidate[candidate_index], match_query[query_index - 1])) continue;

        query_index -= 1;
    }

    assert(candidate_index >= window_start);
    return candidate_index;
}

fn enumerate_match_queries(
    alphabet: []const u8,
    candidate: []const u8,
    query: []u8,
    query_index: usize,
) !void {
    if (query_index == query.len) {
        const expected = rank(query, candidate) != null;
        try std.testing.expectEqual(expected, matches(query, candidate));
        return;
    }

    for (alphabet) |byte| {
        query[query_index] = byte;
        try enumerate_match_queries(alphabet, candidate, query, query_index + 1);
    }
}

fn enumerate_match_candidates(
    alphabet: []const u8,
    candidate: []u8,
    query: []u8,
    candidate_index: usize,
) !void {
    if (candidate_index == candidate.len) {
        try enumerate_match_queries(alphabet, candidate, query, 0);
        return;
    }

    for (alphabet) |byte| {
        candidate[candidate_index] = byte;
        try enumerate_match_candidates(alphabet, candidate, query, candidate_index + 1);
    }
}

fn expect_matches_rank_equivalent(
    alphabet: []const u8,
    candidate_len: usize,
    query_len: usize,
) !void {
    var candidate: [4]u8 = undefined;
    var query: [4]u8 = undefined;
    try enumerate_match_candidates(
        alphabet,
        candidate[0..candidate_len],
        query[0..query_len],
        0,
    );
}

fn boundary_bonus(candidate: []const u8, index: usize) i32 {
    if (index == 0) return BONUS_BOUNDARY_START;

    const previous = candidate[index - 1];
    const boundary_bonus_value = BOUNDARY_BONUSES[previous];
    if (boundary_bonus_value != 0) return boundary_bonus_value;

    if (std.ascii.isLower(previous) and std.ascii.isUpper(candidate[index])) return BONUS_CAMEL_CASE;
    return 0;
}

fn equal_fold(comptime query_is_folded: bool, left: u8, right: u8) bool {
    if (left == right) return true;
    if (query_is_folded) {
        return right >= 'a' and right <= 'z' and left == right - ('a' - 'A');
    }
    return std.ascii.toLower(left) == std.ascii.toLower(right);
}

test "rank prefers consecutive and boundary matches" {
    const consecutive = rank("sct", "/home/scout/").?;
    const scattered = rank("sct", "/home/source-target/").?;
    try std.testing.expect(consecutive.score > scattered.score);

    const boundary = rank("bar", "foo/bar/").?;
    const interior = rank("bar", "foobarbaz/").?;
    try std.testing.expect(boundary.score > interior.score);
}

test "matches uses forward case-insensitive subsequence matching" {
    try std.testing.expect(matches("", "scout"));
    try std.testing.expect(matches("SCT", "/home/scout/"));
    try std.testing.expect(matches("sct", "source-target"));
    try std.testing.expect(!matches("stc", "/home/scout/"));
    try std.testing.expect(!matches("missing", "scout"));
}

test "matches agrees with rank across mixed-case delimiters" {
    try expect_matches_rank_equivalent("aA-_", 4, 4);
}

test "matches agrees with rank when queries exceed candidates" {
    try std.testing.expectEqual(rank("", "") != null, matches("", ""));
    try std.testing.expectEqual(rank("a", "") != null, matches("a", ""));
    try expect_matches_rank_equivalent("bB/.", 2, 4);
}

test "boundary bonuses preserve separator classes" {
    try std.testing.expectEqual(@as(i32, 32), boundary_bonus("a", 0));
    try std.testing.expectEqual(@as(i32, 30), boundary_bonus("/a", 1));
    try std.testing.expectEqual(@as(i32, 26), boundary_bonus(" a", 1));
    try std.testing.expectEqual(@as(i32, 20), boundary_bonus("-a", 1));
    try std.testing.expectEqual(@as(i32, 18), boundary_bonus("aA", 1));
    try std.testing.expectEqual(@as(i32, 0), boundary_bonus("aa", 1));
}

test "positions use the compact alignment" {
    var output: [2]u16 = undefined;
    const matched = positions("ab", "a---ab", &output).?;
    try std.testing.expectEqualSlices(u16, &.{ 4, 5 }, matched);
}

test "prefix matches outrank scattered alternatives" {
    const prefix = rank("foo", "foobaz").?;
    const boundary = rank("foo", "tools-foo").?;
    const scattered = rank("foo", "f-o-o").?;

    try std.testing.expect(prefix.score > boundary.score);
    try std.testing.expect(prefix.score > scattered.score);
}

test "identical prefixes keep identical scores" {
    const first = rank("foo", "foobar").?;
    const second = rank("foo", "foo-tools").?;

    try std.testing.expectEqual(first.score, second.score);
    try std.testing.expectEqual(first.start, second.start);
    try std.testing.expectEqual(first.end, second.end);
}

test "prefix alignment preserves score range and positions" {
    const regular = rank("foo", "foobar").?;
    var output: [3]u16 = undefined;
    const folded = rank_folded_positions("FOO", "foo", "FOO-tools", &output).?;

    try std.testing.expectEqual(regular.score, folded.score);
    try std.testing.expectEqual(@as(usize, 0), folded.start);
    try std.testing.expectEqual(@as(usize, 3), folded.end);
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2 }, output[0..3]);
}

test "rank positions preserve alignment invariants" {
    const cases = [_]struct { query: []const u8, candidate: []const u8 }{
        .{ .query = "sct", .candidate = "/home/scout/" },
        .{ .query = "ab", .candidate = "a---ab" },
        .{ .query = "ABC", .candidate = "prefixABC" },
    };

    for (cases) |case| {
        var output: [16]u16 = undefined;
        const result = rank(case.query, case.candidate).?;
        const matched = positions(case.query, case.candidate, &output).?;

        try std.testing.expectEqual(result.start, @as(usize, matched[0]));
        try std.testing.expectEqual(result.end, @as(usize, matched[matched.len - 1]) + 1);

        for (matched, 0..) |position, query_index| {
            const candidate_index: usize = position;
            try std.testing.expect(candidate_index < case.candidate.len);
            try std.testing.expectEqual(
                std.ascii.toLower(case.query[query_index]),
                std.ascii.toLower(case.candidate[candidate_index]),
            );
            if (query_index > 0) {
                try std.testing.expect(candidate_index > matched[query_index - 1]);
            }
        }
    }
}

test "rank is case insensitive" {
    try std.testing.expect(rank("SCT", "/home/scout/") != null);
    try std.testing.expect(rank("stc", "/home/scout/") == null);
}

test "folded query preserves ranking and positions" {
    const query = "S9";
    const folded_query = "s9";
    const candidate = "Scout-9";

    const regular = rank(query, candidate).?;
    const folded = rank_folded(query, folded_query, candidate).?;
    try std.testing.expectEqual(regular, folded);

    var regular_output: [2]u16 = undefined;
    var folded_output: [2]u16 = undefined;
    var fused_output: [2]u16 = undefined;
    const regular_positions = positions(query, candidate, &regular_output).?;
    const folded_positions = positions_folded(query, folded_query, candidate, &folded_output).?;
    const fused = rank_folded_positions(query, folded_query, candidate, &fused_output).?;
    try std.testing.expectEqual(folded, fused);
    try std.testing.expectEqualSlices(u16, regular_positions, folded_positions);
    try std.testing.expectEqualSlices(u16, folded_positions, &fused_output);
}

test "empty query matches every candidate" {
    try std.testing.expectEqual(@as(i32, 0), rank("", "/home/scout/").?.score);
}
