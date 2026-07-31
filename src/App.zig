//! Scout application orchestration.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Dir = @import("dir.zig");
const Picker = @import("picker/Picker.zig");
const Projects = @import("Projects.zig");
const Tmux = @import("Tmux.zig");

const SessionSource = union(enum) {
    none,
    direct,
    open_control,
};

const LoadContext = struct {
    app: Self,
    root_path: []const u8,
    session_source: SessionSource,
    control: ?*Tmux = null,
};

arena: Allocator,
io: std.Io,
home: ?[]const u8,
inside_tmux: bool,
picker: Picker,

pub fn init(arena: Allocator, io: std.Io, environ_map: *std.process.Environ.Map) Self {
    return .{
        .arena = arena,
        .io = io,
        .home = environ_map.get("HOME"),
        .inside_tmux = environ_map.get("TMUX") != null,
        .picker = .init(arena, io, environ_map),
    };
}

pub fn write_project_names(self: Self, root_path: []const u8, writer: *std.Io.Writer) !void {
    const projects = try self.load_projects(root_path);
    try projects.write_names(writer);
}

pub fn pick_path(self: Self, root_path: []const u8) !?[]const u8 {
    var context: LoadContext = .{
        .app = self,
        .root_path = root_path,
        .session_source = .none,
    };
    const selection = try self.picker.pick(.{
        .context = &context,
        .load = load_picker_entries,
    }) orelse return null;
    return try selection.projects.alloc_path(self.arena, selection.project_index);
}

pub fn open_project_in_tmux(self: Self, root_path: []const u8) !void {
    var context: LoadContext = .{
        .app = self,
        .root_path = root_path,
        .session_source = if (self.inside_tmux) .open_control else .direct,
    };
    const selection_result = self.picker.pick(.{
        .context = &context,
        .load = load_picker_entries,
    });
    // `close` kills and reaps the child on its own error path.
    defer if (context.control) |control| control.close() catch {};

    const selection = try selection_result orelse return;
    const project_path = try selection.projects.alloc_path(self.arena, selection.project_index);

    if (context.control) |control| {
        try control.switch_to_project(project_path);
    } else {
        try Tmux.replace_with_project_session(self.arena, self.io, project_path);
    }
}

fn load_projects(self: Self, root_path: []const u8) !Projects {
    const directory = try Dir.open_absolute(self.arena, self.io, self.home, root_path);
    return discover_projects(self.arena, directory);
}

fn load_picker_entries(opaque_context: *anyopaque) anyerror!Picker.Loaded {
    const context: *LoadContext = @ptrCast(@alignCast(opaque_context));
    const app = context.app;
    const directory = try Dir.open_absolute(app.arena, app.io, app.home, context.root_path);

    var projects_future = app.io.async(discover_projects, .{ app.arena, directory });
    const sessions_result = switch (context.session_source) {
        .none => {
            return .{ .projects = try projects_future.await(app.io) };
        },
        .direct => Tmux.list_sessions_direct(app.arena, app.io),
        .open_control => {
            const control = Tmux.open(app.arena, app.io) catch |err| {
                if (projects_future.await(app.io)) |_| {} else |_| {}
                return err;
            };
            errdefer control.close() catch {};

            const sessions_result = control.list_sessions();
            const projects = try projects_future.await(app.io);
            const sessions = try sessions_result;

            context.control = control;
            return .{
                .projects = projects,
                .sessions = sessions,
            };
        },
    };

    const projects = try projects_future.await(app.io);
    return .{
        .projects = projects,
        .sessions = try sessions_result,
    };
}

fn discover_projects(arena: Allocator, opened_directory: Dir) anyerror!Projects {
    var directory = opened_directory;
    defer directory.close();
    return .init(arena, directory);
}

test {
    _ = Dir;
    _ = Picker;
    _ = Projects;
    _ = Tmux;
}
