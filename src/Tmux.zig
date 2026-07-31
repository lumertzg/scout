//! tmux session creation and attachment, modeled after tmux-sessionizer.

const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const SessionSet = std.StringHashMapUnmanaged(void);

const RESPONSE_BYTES_MAX = 1024 * 1024;
const CONTROL_STDIN_BYTES = 1024;
const CONTROL_STDOUT_BYTES = 64 * 1024;
const DIRECT_READER_BYTES = 4096;

arena: Allocator,
io: std.Io,

child: std.process.Child,

stdin_buffer: [CONTROL_STDIN_BYTES]u8,
stdout_buffer: [CONTROL_STDOUT_BYTES]u8,

stdin_writer: std.Io.File.Writer,
stdout_reader: std.Io.File.Reader,

closed: bool,

/// Starts a control mode client attached to Scout's current session.
pub fn open(arena: Allocator, io: std.Io) !*Self {
    var child = try std.process.spawn(io, .{
        .argv = &.{
            "tmux",
            "-C",
            "attach-session",
            "-f",
            "no-output,ignore-size",
        },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    errdefer child.kill(io);

    const self = try arena.create(Self);
    self.* = .{
        .arena = arena,
        .io = io,
        .child = child,
        .stdin_buffer = undefined,
        .stdout_buffer = undefined,
        .stdin_writer = undefined,
        .stdout_reader = undefined,
        .closed = false,
    };
    self.stdin_writer = self.child.stdin.?.writer(io, &self.stdin_buffer);
    self.stdout_reader = self.child.stdout.?.reader(io, &self.stdout_buffer);

    try read_response(&self.stdout_reader.interface, null, RESPONSE_BYTES_MAX);

    return self;
}

/// Detaches and waits for the control mode client to exit.
pub fn close(self: *Self) !void {
    if (self.closed) return;
    errdefer {
        if (self.child.stdin) |stdin| {
            stdin.close(self.io);
            self.child.stdin = null;
        }

        self.child.kill(self.io);
        self.closed = true;
    }

    if (self.child.stdin) |stdin| {
        try self.stdin_writer.interface.writeByte('\n');
        try self.stdin_writer.interface.flush();
        stdin.close(self.io);
        self.child.stdin = null;
    }

    _ = try self.child.wait(self.io);
    self.closed = true;
}

/// Returns the names of every session reported through the control client.
pub fn list_sessions(self: *Self) !SessionSet {
    var output: std.Io.Writer.Allocating = .init(self.arena);
    self.execute("list-sessions -F \"#{session_name}\"", &output.writer) catch |err| switch (err) {
        error.ResponseTooLarge => {
            self.child.kill(self.io);
            self.closed = true;
            return .empty;
        },
        else => return err,
    };
    return parse_sessions(self.arena, output.written());
}

/// Lists sessions with a one-shot command when Scout is outside tmux.
pub fn list_sessions_direct(arena: Allocator, io: std.Io) !SessionSet {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "tmux", "list-sessions", "-F", "#{session_name}" },
        .stdout = .pipe,
        .stderr = .ignore,
    });
    errdefer child.kill(io);

    const stdout = child.stdout.?;

    var reader_buffer: [DIRECT_READER_BYTES]u8 = undefined;
    var reader = stdout.reader(io, &reader_buffer);

    const output = reader.interface.allocRemaining(arena, .limited(RESPONSE_BYTES_MAX)) catch |err| switch (err) {
        error.StreamTooLong => {
            child.kill(io);
            return .empty;
        },
        else => return err,
    };

    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return .empty;

    return parse_sessions(arena, output);
}

/// Creates the session for `project_path` when missing, then attaches to it.
///
/// Replaces Scout's process image, so this does not return on success. Every
/// caller-owned resource must already be released; see
/// `replace_with_project_session`.
pub fn switch_to_project(self: *Self, project_path: []const u8) !void {
    const name = try session_name(self.arena, project_path);
    var command: std.Io.Writer.Allocating = .init(self.arena);

    try command.writer.writeAll("new-session -Ad -s ");
    try write_quoted_argument(&command.writer, name);
    try command.writer.writeAll(" -c ");
    try write_quoted_argument(&command.writer, project_path);
    try self.execute(command.written(), null);

    // The control client must be reaped here: after the replacement below there
    // is no Scout code left to wait for it.
    try self.close();

    return std.process.replace(self.io, .{
        .argv = &.{ "tmux", "switch-client", "-t", name },
    });
}

/// Creates or attaches without starting a control mode client.
///
/// Replaces Scout's process image so tmux inherits the terminal under Scout's
/// pid, rather than leaving Scout blocked in `wait` for the session's lifetime.
/// This does not return on success, so deferred cleanup never runs: callers
/// must reap their child processes and flush pending output beforehand. Open
/// descriptors need no attention because the standard library opens them
/// CLOEXEC.
pub fn replace_with_project_session(arena: Allocator, io: std.Io, project_path: []const u8) !void {
    const name = try session_name(arena, project_path);
    return std.process.replace(io, .{
        .argv = &.{ "tmux", "new-session", "-A", "-s", name, "-c", project_path },
    });
}

/// Derives the session name from the directory's basename. Returns a slice of
/// `path` unless dots require an arena-owned normalized copy.
pub fn session_name(arena: Allocator, path: []const u8) ![]const u8 {
    const base = session_base(path);

    if (std.mem.indexOfScalar(u8, base, '.') == null) return base;

    const name = try arena.dupe(u8, base);
    std.mem.replaceScalar(u8, name, '.', '_');

    return name;
}

/// Derives a session name without allocating when `buffer` can hold the
/// normalized basename.
pub fn session_name_buffered(path: []const u8, buffer: *[std.Io.Dir.max_name_bytes]u8) []const u8 {
    const base = session_base(path);
    if (std.mem.indexOfScalar(u8, base, '.') == null) return base;
    assert(base.len <= buffer.len);

    @memcpy(buffer[0..base.len], base);
    std.mem.replaceScalar(u8, buffer[0..base.len], '.', '_');
    return buffer[0..base.len];
}

fn session_base(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, std.Io.Dir.path.sep_str);
    return std.Io.Dir.path.basename(trimmed);
}

fn execute(self: *Self, command: []const u8, output: ?*std.Io.Writer) !void {
    try self.stdin_writer.interface.print("{s}\n", .{command});
    try self.stdin_writer.interface.flush();
    try read_response(&self.stdout_reader.interface, output, RESPONSE_BYTES_MAX);
}

fn read_response(reader: *std.Io.Reader, output: ?*std.Io.Writer, response_bytes_max: usize) !void {
    var started = false;
    var output_bytes: usize = 0;

    while (try reader.takeDelimiter('\n')) |line| {
        if (!started) {
            if (std.mem.startsWith(u8, line, "%begin ")) {
                started = true;
            } else if (std.mem.startsWith(u8, line, "%exit")) {
                return error.ControlExited;
            }

            continue;
        }

        if (std.mem.startsWith(u8, line, "%end ")) return;
        if (std.mem.startsWith(u8, line, "%error ")) return error.ControlCommandFailed;

        if (output) |writer| {
            assert(output_bytes <= response_bytes_max);
            const line_bytes = std.math.add(usize, line.len, 1) catch return error.ResponseTooLarge;
            if (line_bytes > response_bytes_max - output_bytes) return error.ResponseTooLarge;
            try writer.print("{s}\n", .{line});
            output_bytes += line_bytes;
        }
    }

    return error.ControlExited;
}

fn write_quoted_argument(writer: *std.Io.Writer, argument: []const u8) !void {
    try writer.writeByte('"');
    for (argument) |byte| {
        try writer.writeByte('\\');
        try writer.writeByte('0' + ((byte >> 6) & 0o7));
        try writer.writeByte('0' + ((byte >> 3) & 0o7));
        try writer.writeByte('0' + (byte & 0o7));
    }
    try writer.writeByte('"');
}

fn parse_sessions(arena: Allocator, output: []const u8) !SessionSet {
    var sessions: SessionSet = .empty;

    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |name| {
        try sessions.put(arena, name, {});
    }

    return sessions;
}

test "session name uses the basename and replaces dots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("scout", try session_name(arena, "/home/user/dev/scout"));
    try std.testing.expectEqualStrings("my_project", try session_name(arena, "/home/user/my.project"));
}

test "session name strips trailing separators before the basename" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectEqualStrings("dev", try session_name(arena_state.allocator(), "/home/user/dev/"));
}

test "session name does not allocate when normalization is unnecessary" {
    try std.testing.expectEqualStrings("scout", try session_name(std.testing.failing_allocator, "/home/user/dev/scout"));
}

test "buffered session name normalizes into caller storage" {
    var buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("my_project", session_name_buffered("/home/user/my.project/", &buffer));
}

test "response reader skips notifications and captures one command block" {
    var reader = std.Io.Reader.fixed(
        "%sessions-changed\n" ++
            "%begin 1 2 1\n" ++
            "alpha\n" ++
            "beta\n" ++
            "%end 1 2 1\n",
    );
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try read_response(&reader, &output.writer, RESPONSE_BYTES_MAX);

    try std.testing.expectEqualStrings("alpha\nbeta\n", output.written());
}

test "response reader reports control command errors" {
    var reader = std.Io.Reader.fixed(
        "%begin 1 2 1\n" ++
            "unknown command\n" ++
            "%error 1 2 1\n",
    );

    try std.testing.expectError(error.ControlCommandFailed, read_response(&reader, null, RESPONSE_BYTES_MAX));
}

test "response reader enforces its byte limit" {
    var reader = std.Io.Reader.fixed("%begin 1 2 1\nalpha\n%end 1 2 1\n");
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try std.testing.expectError(error.ResponseTooLarge, read_response(&reader, &output.writer, 5));
}

test "quoted argument octal-escapes tmux syntax" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try write_quoted_argument(&output.writer, "a b;$'\"");

    try std.testing.expectEqualStrings("\"\\141\\040\\142\\073\\044\\047\\042\"", output.written());
}

test "session parser collects each reported session" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sessions = try parse_sessions(arena, "alpha\nbeta\n");

    try std.testing.expect(sessions.contains("alpha"));
    try std.testing.expect(sessions.contains("beta"));
}
