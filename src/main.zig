//! Scout command-line entry point.

const std = @import("std");
const vaxis = @import("vaxis");
const build_options = @import("build_options");

const App = @import("App.zig");
const Backend = @import("Backend.zig");
const cli = @import("cli.zig");

const STDIO_BUFFER_BYTES = 1024;

/// Restores the terminal before reporting a panic.
pub const panic = vaxis.Panic.call;
pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .vaxis, .level = .err },
        .{ .scope = .vaxis_parser, .level = .err },
    },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const app: App = .init(arena, init.io, init.environ_map);

    var stderr_buffer: [STDIO_BUFFER_BYTES]u8 = undefined;
    var stdout_buffer: [STDIO_BUFFER_BYTES]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);

    const args = try init.minimal.args.toSlice(arena);
    const cli_result = cli.parse_with_env(args, init.environ_map) catch |err| {
        try cli.print_error(&stderr_writer.interface, err);
        try stderr_writer.interface.flush();
        std.process.exit(2);
    };

    if (cli_result.command == .help) {
        try stdout_writer.interface.writeAll(cli.usage);
        try stdout_writer.interface.flush();
        return;
    }

    if (cli_result.command == .version) {
        try stdout_writer.interface.print("scout {s}\n", .{build_options.version});
        try stdout_writer.interface.flush();
        return;
    }

    switch (cli_result.backend) {
        .path => {
            const project_path = if (cli_result.query) |query|
                try app.pick_path_query(cli_result.root_path, query) orelse return
            else
                try app.pick_path(cli_result.root_path) orelse return;
            try stdout_writer.interface.writeAll(project_path);
            try stdout_writer.interface.writeByte('\n');
            try stdout_writer.interface.flush();
        },
        .tmux => try app.open_project_query(cli_result.root_path, cli_result.query, .tmux),
        .herdr => try app.open_project_query(cli_result.root_path, cli_result.query, .herdr),
    }
}

test {
    _ = vaxis;
    _ = App;
    _ = Backend;
    _ = cli;
}
