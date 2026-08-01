//! Command-line argument parsing.

const std = @import("std");

pub const usage =
    \\Usage: scout [options]
    \\
    \\Options:
    \\  --path DIR Directory to search (default: ~/Projects)
    \\  --no-tmux  Print the selected directory instead of opening tmux
    \\  -h, --help Show this help
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
    no_tmux: bool = false,
};

/// Errors caused by invalid command-line arguments.
pub const ParseError = error{
    MissingPathValue,
    UnexpectedArgument,
    UnknownOption,
};

/// Returns a short user-facing explanation for `err`.
pub fn error_message(err: ParseError) []const u8 {
    return switch (err) {
        error.MissingPathValue => "expected a directory after --path",
        error.UnexpectedArgument => "unexpected argument, use --path to set the directory",
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
    var result: Result = .{};

    const command_args = if (args.len > 0) args[1..] else args;
    var index: usize = 0;
    while (index < command_args.len) : (index += 1) {
        const arg = command_args[index];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            result.command = .help;
            return result;
        }

        if (std.mem.eql(u8, arg, "--no-tmux")) {
            result.no_tmux = true;
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

    return result;
}

test "defaults to the Projects directory" {
    const result = try parse(&.{"scout"});

    try std.testing.expectEqual(.run, result.command);
    try std.testing.expectEqualStrings("~/Projects", result.root_path);
}

test "parses a root path" {
    const result = try parse(&.{ "scout", "--path", "/home/user/dev" });

    try std.testing.expectEqual(.run, result.command);
    try std.testing.expectEqualStrings("/home/user/dev", result.root_path);

    const equals = try parse(&.{ "scout", "--path=/home/user/dev" });
    try std.testing.expectEqualStrings("/home/user/dev", equals.root_path);
}

test "parses no-tmux" {
    const result = try parse(&.{ "scout", "--no-tmux" });

    try std.testing.expect(result.no_tmux);
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
    try std.testing.expectError(error.UnknownOption, parse(&.{ "scout", "--wat" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "scout", "--picker" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "scout", "list" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "scout", "one" }));
    try std.testing.expectError(error.MissingPathValue, parse(&.{ "scout", "--path" }));
}
