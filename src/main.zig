//! Scout command-line entry point.

const std = @import("std");
const vaxis = @import("vaxis");
const App = @import("App.zig");
const Config = @import("Config.zig");
const zlap = @import("zlap");

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
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);

    const config = zlap.parse(Config, init);
    const mode = config.resolve_mode(arena, init.environ_map) catch |err| {
        if (err == error.OutOfMemory) return err;

        const config_err: Config.Error = @errorCast(err);
        try stderr_writer.interface.print("scout: {s}\n", .{Config.error_message(config_err)});
        try stderr_writer.interface.flush();

        std.process.exit(2);
    };

    const app: App = .init(arena, init.io, init.environ_map.get("HOME"), init.environ_map);

    switch (mode) {
        .path => {
            const project_path = if (config.query) |query|
                try app.pick_path_query(config.root_path, query) orelse return
            else
                try app.pick_path(config.root_path) orelse return;
            var stdout_buffer: [STDIO_BUFFER_BYTES]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
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
    _ = zlap;
}
