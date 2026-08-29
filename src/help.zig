//! User-facing command usage and configuration errors.

const std = @import("std");

const Config = @import("Config.zig");

pub const usage =
    \\Usage: scout [QUERY] [options]
    \\
    \\Options:
    \\  --path DIR Directory to search (default: ~/Projects)
    \\  --backend NAME Backend to use: path, tmux, or herdr (default: path)
    \\  -h, --help Show this help
    \\  -V, --version Show version
    \\
    \\An exact or unique fuzzy match selects directly. Otherwise, the picker
    \\opens with the query entered.
    \\
    \\Environment:
    \\  SCOUT_PATH Default directory. Overridden by --path
    \\  SCOUT_BACKEND Default backend. Overridden by --backend
    \\
;

/// Returns a short user-facing explanation for a configuration error.
pub fn error_message(err: Config.ConfigErr) []const u8 {
    return switch (err) {
        error.MissingPathValue => "expected a directory after --path",
        error.MissingBackendValue => "expected path, tmux, or herdr after --backend",
        error.InvalidBackend => "backend must be path, tmux, or herdr",
        error.UnexpectedArgument => "unexpected positional argument",
        error.UnknownOption => "unknown option",
        error.InvalidSocketPath => "HERDR_SOCKET_PATH must not be empty",
        error.InvalidSessionName => "HERDR_SESSION must be a valid session name",
    };
}

/// Prints a configuration error followed by command usage.
pub fn print_error(writer: *std.Io.Writer, err: Config.ConfigErr) std.Io.Writer.Error!void {
    try writer.print("scout: {s}\n\n{s}", .{ error_message(err), usage });
}

test "messages explain every configuration error" {
    inline for (std.meta.fields(Config.ConfigErr)) |field| {
        const err: Config.ConfigErr = @field(Config.ConfigErr, field.name);
        try std.testing.expect(error_message(err).len > 0);
    }
}
