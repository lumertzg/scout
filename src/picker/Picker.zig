//! Scout's in-process terminal picker.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Entries = @import("Entries.zig");
const Projects = @import("../Projects.zig");
const Tmux = @import("../Tmux.zig");
const Ui = @import("Ui.zig");

arena: Allocator,
io: std.Io,
environ_map: *std.process.Environ.Map,

pub fn init(arena: Allocator, io: std.Io, environ_map: *std.process.Environ.Map) Self {
    return .{
        .arena = arena,
        .io = io,
        .environ_map = environ_map,
    };
}

/// Opens the picker and returns the selected project's original index.
pub fn pick_project(self: Self, projects: Projects) !?usize {
    const entries = Entries.from_projects(projects);
    const ui: Ui = .init(self.arena, self.io, self.environ_map, entries);
    return ui.pick();
}

/// Marks active sessions and puts them first in the initial ordering.
pub fn pick_project_with_sessions(self: Self, projects: Projects, sessions: Tmux.SessionSet) !?usize {
    const entries = try Entries.with_active_sessions(self.arena, projects, sessions);
    const ui: Ui = .init(self.arena, self.io, self.environ_map, entries);
    return ui.pick();
}

test {
    _ = Entries;
    _ = Ui;
}
