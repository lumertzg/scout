//! Scout build graph.

const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Version reported by scout") orelse
        manifest.version;
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const zlap = b.dependency("zlap", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "scout",
        // GNU libc startup objects need LLVM for SFrame relocations.
        // https://codeberg.org/ziglang/zig/issues/31272
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("vaxis", vaxis.module("vaxis"));
    exe.root_module.addImport("zlap", zlap.module("zlap"));
    exe.root_module.addOptions("build_options", build_options);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

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
    exe_tests.root_module.addImport("zlap", zlap.module("zlap"));
    exe_tests.root_module.addOptions("build_options", build_options);
    test_step.dependOn(&exe.step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const fmt_check = b.addFmt(.{
        .paths = &.{
            b.path("src"),
            b.path("build.zig"),
            b.path("build.zig.zon"),
            b.path(".ziglint.zon"),
        },
        .check = true,
    });
    test_step.dependOn(&fmt_check.step);
}
