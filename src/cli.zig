//! Command-line argument parsing.

const std = @import("std");
const Backend = @import("Backend.zig").Backend;

pub const usage =
    \\Usage: scout [options]
    \\
    \\Options:
    \\  --path DIR Directory to search (default: ~/Projects)
    \\  --backend NAME Backend to use: path, tmux, or kitty (default: path)
    \\  -h, --help Show this help
    \\
    \\Environment:
    \\  SCOUT_BACKEND Default backend. overridden by --backend
    \\
;

/// Top-level command selected by parsing.
pub const Command = enum {
    run,
    help,
};

/// Parsed command-line options.
pub const Result = struct {
    /// Root whose direct children are offered as projects.
    root_path: []const u8 = "~/Projects",
    command: Command = .run,
    backend: Backend = .path,
};

/// Errors caused by invalid command-line arguments.
pub const ParseError = error{
    MissingPathValue,
    MissingBackendValue,
    InvalidBackend,
    UnexpectedArgument,
    UnknownOption,
};

/// Returns a short user-facing explanation for `err`.
pub fn error_message(err: ParseError) []const u8 {
    return switch (err) {
        error.MissingPathValue => "expected a directory after --path",
        error.MissingBackendValue => "expected path, tmux, or kitty after --backend",
        error.InvalidBackend => "backend must be path, tmux, or kitty",
        error.UnexpectedArgument => "unexpected positional argument",
        error.UnknownOption => "unknown option",
    };
}

/// Prints a parse error followed by command usage.
pub fn print_error(writer: *std.Io.Writer, err: ParseError) std.Io.Writer.Error!void {
    try writer.print("scout: {s}\n\n{s}", .{
        error_message(err),
        usage,
    });
}

/// Parses the complete argument vector, including the executable name,
/// without allocating.
pub fn parse(args: []const []const u8) ParseError!Result {
    return parse_with_backend_default(args, null);
}

/// Parses arguments with defaults read from `environ_map`.
pub fn parse_with_env(args: []const []const u8, environ_map: *const std.process.Environ.Map) ParseError!Result {
    return parse_with_backend_default(args, environ_map.get("SCOUT_BACKEND"));
}

fn parse_with_backend_default(args: []const []const u8, backend_env: ?[]const u8) ParseError!Result {
    var result: Result = .{};
    var backend_from_cli = false;

    const command_args = if (args.len > 0) args[1..] else args;
    var index: usize = 0;
    while (index < command_args.len) : (index += 1) {
        const arg = command_args[index];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            result.command = .help;
            return result;
        }

        if (std.mem.eql(u8, arg, "--backend")) {
            index += 1;
            if (index >= command_args.len) return error.MissingBackendValue;
            result.backend = try parse_backend(command_args[index]);
            backend_from_cli = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--backend=")) {
            result.backend = try parse_backend(arg["--backend=".len..]);
            backend_from_cli = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--path")) {
            index += 1;
            if (index >= command_args.len) return error.MissingPathValue;
            result.root_path = command_args[index];
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--path=")) {
            result.root_path = arg["--path=".len..];
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        }

        return error.UnexpectedArgument;
    }

    if (!backend_from_cli) {
        if (backend_env) |value| result.backend = try parse_backend(value);
    }

    return result;
}

fn parse_backend(value: []const u8) ParseError!Backend {
    if (std.mem.eql(u8, value, "path")) return .path;
    if (std.mem.eql(u8, value, "tmux")) return .tmux;
    if (std.mem.eql(u8, value, "kitty")) return .kitty;
    return error.InvalidBackend;
}

fn test_backend_environ(value: []const u8) !std.process.Environ.Map {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    errdefer environ_map.deinit();

    try environ_map.put("SCOUT_BACKEND", value);
    return environ_map;
}

test "defaults to the Projects directory" {
    const result = try parse(&.{"scout"});

    try std.testing.expectEqual(.run, result.command);
    try std.testing.expectEqualStrings("~/Projects", result.root_path);
    try std.testing.expectEqual(Backend.path, result.backend);
}

test "parses a root path" {
    const result = try parse(&.{ "scout", "--path", "/home/user/dev" });

    try std.testing.expectEqual(.run, result.command);
    try std.testing.expectEqualStrings("/home/user/dev", result.root_path);

    const equals = try parse(&.{ "scout", "--path=/home/user/dev" });
    try std.testing.expectEqualStrings("/home/user/dev", equals.root_path);
}

test "parses backend with separate and equals values" {
    const tmux = try parse(&.{ "scout", "--backend", "tmux" });
    try std.testing.expectEqual(Backend.tmux, tmux.backend);

    const kitty = try parse(&.{ "scout", "--backend=kitty" });
    try std.testing.expectEqual(Backend.kitty, kitty.backend);
}

test "environment selects the backend when the CLI does not" {
    var environ_map = try test_backend_environ("kitty");
    defer environ_map.deinit();

    const result = try parse_with_env(&.{"scout"}, &environ_map);
    try std.testing.expectEqual(Backend.kitty, result.backend);
}

test "CLI backend overrides the environment" {
    var environ_map = try test_backend_environ("invalid");
    defer environ_map.deinit();

    const result = try parse_with_env(&.{ "scout", "--backend=tmux" }, &environ_map);
    try std.testing.expectEqual(Backend.tmux, result.backend);
}

test "rejects an invalid environment backend when no CLI override exists" {
    var environ_map = try test_backend_environ("invalid");
    defer environ_map.deinit();

    try std.testing.expectError(error.InvalidBackend, parse_with_env(&.{"scout"}, &environ_map));
}

test "help ignores an invalid environment backend" {
    var environ_map = try test_backend_environ("invalid");
    defer environ_map.deinit();

    const result = try parse_with_env(&.{ "scout", "--help" }, &environ_map);
    try std.testing.expectEqual(Command.help, result.command);
}

test "parses help flags" {
    try std.testing.expectEqual(.help, (try parse(&.{ "scout", "-h" })).command);
    try std.testing.expectEqual(.help, (try parse(&.{ "scout", "--help" })).command);
}

test "path option permits a directory beginning with a dash" {
    const result = try parse(&.{ "scout", "--path=-projects" });

    try std.testing.expectEqualStrings("-projects", result.root_path);
}

test "rejects unknown options, positional arguments, and a missing path value" {
    const Case = struct {
        expected: ParseError,
        args: []const []const u8,
    };
    const cases = [_]Case{
        .{ .expected = error.UnknownOption, .args = &.{ "scout", "--wat" } },
        .{ .expected = error.UnknownOption, .args = &.{ "scout", "--picker" } },
        .{ .expected = error.UnexpectedArgument, .args = &.{ "scout", "list" } },
        .{ .expected = error.UnexpectedArgument, .args = &.{ "scout", "one" } },
        .{ .expected = error.MissingPathValue, .args = &.{ "scout", "--path" } },
        .{ .expected = error.UnknownOption, .args = &.{ "scout", "--kitty" } },
        .{ .expected = error.UnknownOption, .args = &.{ "scout", "--no-tmux" } },
        .{ .expected = error.MissingBackendValue, .args = &.{ "scout", "--backend" } },
        .{ .expected = error.InvalidBackend, .args = &.{ "scout", "--backend=" } },
        .{ .expected = error.InvalidBackend, .args = &.{ "scout", "--backend=other" } },
    };

    for (cases) |case| {
        try std.testing.expectError(case.expected, parse(case.args));
    }
}
