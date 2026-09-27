//! Application configuration.

const Self = @This();

const std = @import("std");
const zlap = @import("zlap");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const EnvironMap = std.process.Environ.Map;

const HerdrBackend = @import("Herdr.zig");

/// Errors in the environment used to initialize the Herdr backend.
pub const Error = error{
    InvalidSocketPath,
    InvalidSessionName,
};

/// Directory whose direct children are offered as projects.
root_path: []const u8 = "~/Projects",
/// Backend selected at startup.
backend: Backend = .path,
/// Optional fuzzy query for non-interactive selection.
query: ?[]const u8 = null,

pub const meta: zlap.Meta(Self) = .{
    .bin = "scout",
    .version = build_options.version,
    .about = "Pick a project directory.",
    .fields = .{
        .root_path = .{
            .long = "path",
            .value_name = "DIR",
            .help = "Directory to search (default: ~/Projects).",
            .env = "SCOUT_PATH",
            .allow_hyphen_values = true,
        },
        .backend = .{
            .value_name = "BACKEND",
            .help = "Backend to use: path, tmux, or herdr (default: path).",
            .env = "SCOUT_BACKEND",
        },
        .query = .{
            .positional = true,
            .value_name = "QUERY",
            .help = "Optional project name or fuzzy query.",
        },
    },
};

/// Backend selected at startup.
pub const Backend = enum {
    path,
    tmux,
    herdr,
};

/// Runtime state needed by the selected backend.
pub const Mode = union(enum) {
    path,
    tmux: Tmux,
    herdr: Herdr,

    pub const Tmux = struct {
        inside: bool,
    };

    pub const Herdr = struct {
        inside: bool,
        socket_path: []const u8,
    };
};

/// Resolves runtime state only for the selected backend.
pub fn resolve_mode(
    self: Self,
    arena: Allocator,
    environ_map: *const EnvironMap,
) (Error || Allocator.Error)!Mode {
    return switch (self.backend) {
        .path => .path,
        .tmux => .{ .tmux = .{
            .inside = environ_map.get("TMUX") != null,
        } },
        .herdr => .{ .herdr = .{
            .inside = std.mem.eql(u8, environ_map.get("HERDR_ENV") orelse "", "1"),
            .socket_path = try HerdrBackend.resolve_socket_path(arena, environ_map),
        } },
    };
}

/// Explains invalid Herdr environment settings.
pub fn error_message(err: Error) []const u8 {
    return switch (err) {
        error.InvalidSocketPath => "HERDR_SOCKET_PATH must not be empty",
        error.InvalidSessionName => "HERDR_SESSION must be a valid session name",
    };
}

fn test_environ() !EnvironMap {
    return EnvironMap.init(std.testing.allocator);
}

fn parse_args(environ_map: *const EnvironMap, values: []const []const u8) zlap.Error!Self {
    return zlap.parseFrom(Self, std.testing.allocator, .{
        .program = "scout",
        .values = values,
    }, .{ .env = .{ .map = environ_map } });
}

test "arguments override environment and can surround the query" {
    var environ_map = try test_environ();
    defer environ_map.deinit();
    try environ_map.put("SCOUT_PATH", "/environment/projects");
    try environ_map.put("SCOUT_BACKEND", "herdr");

    const before = try parse_args(&environ_map, &.{
        "query", "--path", "/arguments/projects", "--backend=tmux",
    });
    try std.testing.expectEqualStrings("query", before.query.?);
    try std.testing.expectEqualStrings("/arguments/projects", before.root_path);
    try std.testing.expectEqual(.tmux, before.backend);

    const after = try parse_args(&environ_map, &.{ "--backend", "tmux", "query" });
    try std.testing.expectEqualStrings("query", after.query.?);
    try std.testing.expectEqual(.tmux, after.backend);
}

test "arguments use environment defaults and accept hyphenated paths" {
    var environ_map = try test_environ();
    defer environ_map.deinit();
    try environ_map.put("SCOUT_PATH", "/environment/projects");
    try environ_map.put("SCOUT_BACKEND", "tmux");

    const environment = try parse_args(&environ_map, &.{});
    try std.testing.expectEqualStrings("/environment/projects", environment.root_path);
    try std.testing.expectEqual(.tmux, environment.backend);
    try std.testing.expect(environment.query == null);

    const hyphen_path = try parse_args(&environ_map, &.{ "--path", "-projects" });
    try std.testing.expectEqualStrings("-projects", hyphen_path.root_path);
}

test "invalid backend values and native actions produce zlap outcomes" {
    var environ_map = try test_environ();
    defer environ_map.deinit();
    try environ_map.put("SCOUT_BACKEND", "invalid");

    var diagnostic: zlap.Diagnostic = .{};
    try std.testing.expectError(error.ParseFailed, zlap.parseFrom(
        Self,
        std.testing.allocator,
        .{ .program = "scout" },
        .{ .env = .{ .map = &environ_map }, .diagnostic = &diagnostic },
    ));
    try std.testing.expectEqual(.invalid_value, diagnostic.kind);

    try std.testing.expectError(error.HelpRequested, zlap.parseFrom(
        Self,
        std.testing.allocator,
        .{ .program = "scout", .values = &.{"help"} },
        .{ .env = .{ .map = &environ_map } },
    ));

    const escaped = try parse_args(&environ_map, &.{ "--backend=path", "--", "help" });
    try std.testing.expectEqualStrings("help", escaped.query.?);
    try std.testing.expectEqual(.path, escaped.backend);
}

test "configuration resolves only the selected backend state" {
    var environ_map = try test_environ();
    defer environ_map.deinit();
    try environ_map.put("HERDR_SOCKET_PATH", "");
    try environ_map.put("TMUX", "/tmp/tmux");

    const tmux: Self = .{ .backend = .tmux };
    const tmux_mode = try tmux.resolve_mode(std.testing.allocator, &environ_map);
    try std.testing.expect(tmux_mode.tmux.inside);

    const herdr: Self = .{ .backend = .herdr };
    try std.testing.expectError(
        error.InvalidSocketPath,
        herdr.resolve_mode(std.testing.allocator, &environ_map),
    );
}

test "configuration resolves Herdr state when selected" {
    var environ_map = try test_environ();
    defer environ_map.deinit();
    try environ_map.put("HERDR_ENV", "1");
    try environ_map.put("HERDR_SOCKET_PATH", "/tmp/herdr.sock");

    const config: Self = .{ .backend = .herdr };
    const mode = try config.resolve_mode(std.testing.allocator, &environ_map);
    try std.testing.expect(mode.herdr.inside);
    try std.testing.expectEqualStrings("/tmp/herdr.sock", mode.herdr.socket_path);
}
