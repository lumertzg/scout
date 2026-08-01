//! Scout build graph.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "scout",
        // Zig 0.16's self-hosted x86 backend cannot yet link the SFrame
        // relocations emitted by current GNU libc startup objects:
        // https://codeberg.org/ziglang/zig/issues/31272
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("vaxis", vaxis.module("vaxis"));
    exe.root_module.linkSystemLibrary("c", .{});
    exe.root_module.linkSystemLibrary("git2", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const exe_tests = b.addTest(.{
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_tests.root_module.addImport("vaxis", vaxis.module("vaxis"));
    exe_tests.root_module.linkSystemLibrary("c", .{});
    exe_tests.root_module.linkSystemLibrary("git2", .{});
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    test_step.dependOn(&fmt_check.step);
}
