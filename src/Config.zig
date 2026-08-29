//! Application configuration.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArgsIterator = std.process.Args.Iterator;
const EnvironMap = std.process.Environ.Map;

const HerdrBackend = @import("Herdr.zig");

/// Errors caused by invalid command-line arguments or environment settings.
pub const Error = error{
    MissingPathValue,
    MissingBackendValue,
    InvalidBackend,
    UnexpectedArgument,
    UnknownOption,
    InvalidSocketPath,
    InvalidSessionName,
};

/// Directory whose direct children are offered as projects.
root_path: []const u8 = "~/Projects",
/// The action and backend state selected at startup.
mode: Mode = .path,
/// Optional fuzzy query for non-interactive selection.
query: ?[]const u8 = null,
/// User home directory used to expand `root_path`.
home: ?[]const u8 = null,

/// Top-level action selected at startup.
pub const Mode = union(enum) {
    help,
    version,
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

    fn tag_from_backend(value: []const u8) Error!std.meta.Tag(Mode) {
        if (std.mem.eql(u8, value, "path")) return .path;
        if (std.mem.eql(u8, value, "tmux")) return .tmux;
        if (std.mem.eql(u8, value, "herdr")) return .herdr;
        return error.InvalidBackend;
    }
};

const Arg = struct {
    long: []const u8,
    missing_error: Error,

    fn parse(comptime self: Arg, source: []const u8, args: *ArgsIterator) Error!?[]const u8 {
        if (!std.mem.startsWith(u8, source, "--")) return null;

        const option = source[2..];
        if (std.mem.eql(u8, option, self.long)) {
            return args.next() orelse return self.missing_error;
        }

        const has_inline_value = option.len > self.long.len and
            option[self.long.len] == '=' and
            std.mem.eql(u8, option[0..self.long.len], self.long);
        if (has_inline_value) return option[self.long.len + 1 ..];

        return null;
    }
};

/// Loads configuration with command-line values overriding the environment.
pub fn init(
    arena: Allocator,
    environ_map: *const EnvironMap,
    args: *ArgsIterator,
) (Error || Allocator.Error)!Self {
    const path_arg: Arg = .{
        .long = "path",
        .missing_error = error.MissingPathValue,
    };
    const backend_arg: Arg = .{
        .long = "backend",
        .missing_error = error.MissingBackendValue,
    };

    var self: Self = .{
        .root_path = environ_map.get("SCOUT_PATH") orelse "~/Projects",
        .home = environ_map.get("HOME"),
    };
    var mode_override: ?std.meta.Tag(Mode) = null;

    _ = args.skip();
    while (args.next()) |source| {
        if (std.mem.eql(u8, source, "-h") or std.mem.eql(u8, source, "--help")) {
            self.mode = .help;
            return self;
        }
        if (std.mem.eql(u8, source, "-V") or std.mem.eql(u8, source, "--version")) {
            self.mode = .version;
            return self;
        }

        if (try path_arg.parse(source, args)) |value| {
            self.root_path = value;
            continue;
        }
        if (try backend_arg.parse(source, args)) |value| {
            mode_override = try Mode.tag_from_backend(value);
            continue;
        }

        if (std.mem.startsWith(u8, source, "-")) return error.UnknownOption;
        if (self.query != null) return error.UnexpectedArgument;
        self.query = source;
    }

    const mode = mode_override orelse try backend_from_env(environ_map);
    self.mode = switch (mode) {
        .help => .help,
        .version => .version,
        .path => .path,
        .tmux => .{ .tmux = .{ .inside = environ_map.get("TMUX") != null } },
        .herdr => .{ .herdr = .{
            .inside = std.mem.eql(u8, environ_map.get("HERDR_ENV") orelse "", "1"),
            .socket_path = try HerdrBackend.resolve_socket_path(arena, environ_map),
        } },
    };
    return self;
}

fn backend_from_env(environ_map: *const EnvironMap) Error!std.meta.Tag(Mode) {
    const value = environ_map.get("SCOUT_BACKEND") orelse return .path;
    return Mode.tag_from_backend(value);
}

fn test_environ(backend: ?[]const u8) !EnvironMap {
    var environ_map = EnvironMap.init(std.testing.allocator);
    errdefer environ_map.deinit();
    if (backend) |value| try environ_map.put("SCOUT_BACKEND", value);
    return environ_map;
}

fn test_init(environ_map: *const EnvironMap, args: std.process.Args.Vector) (Error || Allocator.Error)!Self {
    const process_args: std.process.Args = .{ .vector = args };
    var iterator = process_args.iterate();
    return init(std.testing.allocator, environ_map, &iterator);
}

test "defaults to the Projects directory and path mode" {
    var environ_map = try test_environ(null);
    defer environ_map.deinit();

    const config = try test_init(&environ_map, &.{"scout"});
    try std.testing.expectEqualStrings("~/Projects", config.root_path);
    try std.testing.expect(config.query == null);
    try std.testing.expectEqual(.path, std.meta.activeTag(config.mode));
}

test "arguments override environment before mode resolution" {
    var environ_map = try test_environ("herdr");
    defer environ_map.deinit();
    try environ_map.put("SCOUT_PATH", "/environment/projects");
    try environ_map.put("HERDR_SOCKET_PATH", "");
    try environ_map.put("TMUX", "/tmp/tmux");

    const config = try test_init(&environ_map, &.{
        "scout", "needle", "--path", "/arguments/projects", "--backend=tmux",
    });
    try std.testing.expectEqualStrings("/arguments/projects", config.root_path);
    try std.testing.expectEqualStrings("needle", config.query.?);
    try std.testing.expectEqual(.tmux, std.meta.activeTag(config.mode));
    try std.testing.expect(config.mode.tmux.inside);
}

test "positional queries allow options before or after them" {
    var environ_map = try test_environ(null);
    defer environ_map.deinit();

    const before = try test_init(&environ_map, &.{
        "scout", "query", "--path", "/projects", "--backend=tmux",
    });
    try std.testing.expectEqualStrings("query", before.query.?);
    try std.testing.expectEqualStrings("/projects", before.root_path);
    try std.testing.expectEqual(.tmux, std.meta.activeTag(before.mode));

    const after = try test_init(&environ_map, &.{
        "scout", "--backend", "tmux", "query",
    });
    try std.testing.expectEqualStrings("query", after.query.?);
    try std.testing.expectEqual(.tmux, std.meta.activeTag(after.mode));
}

test "backend flag parses separate and inline values" {
    var environ_map = try test_environ(null);
    defer environ_map.deinit();
    try environ_map.put("HERDR_SOCKET_PATH", "/tmp/herdr.sock");

    const tmux = try test_init(&environ_map, &.{ "scout", "--backend", "tmux" });
    try std.testing.expectEqual(.tmux, std.meta.activeTag(tmux.mode));
    const herdr = try test_init(&environ_map, &.{ "scout", "--backend=herdr" });
    try std.testing.expectEqual(.herdr, std.meta.activeTag(herdr.mode));
}

test "path option permits a directory beginning with a dash" {
    var environ_map = try test_environ(null);
    defer environ_map.deinit();

    const inline_path = try test_init(&environ_map, &.{ "scout", "--path=-projects" });
    try std.testing.expectEqualStrings("-projects", inline_path.root_path);
    const separate = try test_init(&environ_map, &.{ "scout", "--path", "-projects" });
    try std.testing.expectEqualStrings("-projects", separate.root_path);
}

test "CLI backend overrides an invalid environment backend" {
    var environ_map = try test_environ("invalid");
    defer environ_map.deinit();

    const config = try test_init(&environ_map, &.{ "scout", "--backend=tmux" });
    try std.testing.expectEqual(.tmux, std.meta.activeTag(config.mode));
}

test "invalid environment backend is rejected without a CLI override" {
    var environ_map = try test_environ("invalid");
    defer environ_map.deinit();
    try std.testing.expectError(error.InvalidBackend, test_init(&environ_map, &.{"scout"}));
}

test "informational flags ignore invalid environment" {
    var environ_map = try test_environ("invalid");
    defer environ_map.deinit();

    const help_flags = [_][*:0]const u8{ "-h", "--help" };
    for (help_flags) |flag| {
        const help = try test_init(&environ_map, &.{ "scout", flag });
        try std.testing.expectEqual(.help, std.meta.activeTag(help.mode));
    }
    const version_flags = [_][*:0]const u8{ "-V", "--version" };
    for (version_flags) |flag| {
        const version = try test_init(&environ_map, &.{ "scout", flag });
        try std.testing.expectEqual(.version, std.meta.activeTag(version.mode));
    }
}

test "help and version flags stop argument processing" {
    var environ_map = try test_environ(null);
    defer environ_map.deinit();

    const help = try test_init(&environ_map, &.{ "scout", "-h", "--unknown" });
    try std.testing.expectEqual(.help, std.meta.activeTag(help.mode));
    const version = try test_init(&environ_map, &.{ "scout", "--version", "--unknown" });
    try std.testing.expectEqual(.version, std.meta.activeTag(version.mode));
}

test "herdr mode resolves environment-backed state" {
    var environ_map = try test_environ("herdr");
    defer environ_map.deinit();
    try environ_map.put("HERDR_ENV", "1");
    try environ_map.put("HERDR_SOCKET_PATH", "/tmp/herdr.sock");

    const config = try test_init(&environ_map, &.{"scout"});
    try std.testing.expect(config.mode.herdr.inside);
    try std.testing.expectEqualStrings("/tmp/herdr.sock", config.mode.herdr.socket_path);
}

test "argument parsing rejects invalid values" {
    var environ_map = try test_environ(null);
    defer environ_map.deinit();

    const Case = struct { expected: Error, args: std.process.Args.Vector };
    const cases = [_]Case{
        .{ .expected = error.UnknownOption, .args = &.{ "scout", "--wat" } },
        .{ .expected = error.UnknownOption, .args = &.{ "scout", "--picker" } },
        .{ .expected = error.UnknownOption, .args = &.{ "scout", "--no-tmux" } },
        .{ .expected = error.UnexpectedArgument, .args = &.{ "scout", "one", "two" } },
        .{ .expected = error.MissingPathValue, .args = &.{ "scout", "--path" } },
        .{ .expected = error.MissingBackendValue, .args = &.{ "scout", "--backend" } },
        .{ .expected = error.InvalidBackend, .args = &.{ "scout", "--backend=" } },
        .{ .expected = error.InvalidBackend, .args = &.{ "scout", "--backend=other" } },
    };
    for (cases) |case| try std.testing.expectError(case.expected, test_init(&environ_map, case.args));
}
