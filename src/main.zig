//! Scout command-line entry point.

const std = @import("std");
const vaxis = @import("vaxis");
const build_options = @import("build_options");

const App = @import("App.zig");
const Config = @import("Config.zig");
const help = @import("help.zig");

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
    var stderr_buffer: [STDIO_BUFFER_BYTES]u8 = undefined;
    var stdout_buffer: [STDIO_BUFFER_BYTES]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);

    const args = try init.minimal.args.toSlice(arena);
    const config = Config.init(arena, init.environ_map, args) catch |err| {
        if (err == error.OutOfMemory) return err;
        const config_err: Config.ConfigErr = @errorCast(err);
        try help.print_error(&stderr_writer.interface, config_err);
        try stderr_writer.interface.flush();
        std.process.exit(2);
    };

    const app: App = .init(arena, init.io, config.home, init.environ_map);

    switch (config.mode) {
        .help => {
            try stdout_writer.interface.writeAll(help.usage);
            try stdout_writer.interface.flush();
        },
        .version => {
            try stdout_writer.interface.print("scout {s}\n", .{build_options.version});
            try stdout_writer.interface.flush();
        },
        .path => {
            const project_path = if (config.query) |query|
                try app.pick_path_query(config.root_path, query) orelse return
            else
                try app.pick_path(config.root_path) orelse return;
            try stdout_writer.interface.writeAll(project_path);
            try stdout_writer.interface.writeByte('\n');
            try stdout_writer.interface.flush();
        },
        .tmux => |tmux| try app.open_tmux_project_query(config.root_path, config.query, tmux),
        .herdr => |herdr| try app.open_herdr_project_query(config.root_path, config.query, herdr),
    }
}

test {
    _ = vaxis;
    _ = App;
    _ = Config;
    _ = help;
}
