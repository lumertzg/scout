//! Scout application orchestration.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Dir = @import("dir.zig");
const Picker = @import("picker/Picker.zig");
const Projects = @import("Projects.zig");
const Tmux = @import("Tmux.zig");

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
    const projects = try self.load_projects(root_path);
    const project_index = try self.picker.pick_project(projects) orelse return null;
    return try projects.alloc_path(self.arena, project_index);
}

pub fn open_project_in_tmux(self: Self, root_path: []const u8) !void {
    const directory = try Dir.open_absolute(self.arena, self.io, self.home, root_path);
    var projects_future = self.io.async(discover_projects, .{ self.arena, directory });

    var tmux: ?*Tmux = null;
    if (self.inside_tmux) {
        tmux = Tmux.open(self.arena, self.io) catch |err| {
            // Await transfers directory cleanup back from the discovery task.
            if (projects_future.await(self.io)) |_| {} else |_| {}
            return err;
        };
    }
    // `close` kills and reaps the child on its own error path.
    defer if (tmux) |control| control.close() catch {};

    const sessions_result = if (tmux) |control|
        control.list_sessions()
    else
        Tmux.list_sessions_direct(self.arena, self.io);

    const projects = try projects_future.await(self.io);
    const sessions = try sessions_result;
    const project_index = try self.picker.pick_project_with_sessions(projects, sessions) orelse return;
    const project_path = try projects.alloc_path(self.arena, project_index);

    if (tmux) |control| {
        try control.switch_to_project(project_path);
    } else {
        try Tmux.replace_with_project_session(self.arena, self.io, project_path);
    }
}

fn load_projects(self: Self, root_path: []const u8) !Projects {
    const directory = try Dir.open_absolute(self.arena, self.io, self.home, root_path);
    return discover_projects(self.arena, directory);
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
