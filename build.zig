const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nanovg_dep = b.dependency("nanovg", .{});
    const zzplot_dep = b.dependency("zzplot", .{});
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zzplot", .module = zzplot_dep.module("ZZPlot") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "Prj",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const filter_opt = b.option([]const u8, "test-filter", "filter tests");
    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
        .filters = if (filter_opt) |f| &.{f} else &.{},
    });

    exe_unit_tests.root_module.addCSourceFile(.{ .file = nanovg_dep.path("lib/gl2/src/glad.c"), .flags = &.{} });
    exe_unit_tests.root_module.addIncludePath(nanovg_dep.path("lib/gl2/include"));
    exe_unit_tests.root_module.linkSystemLibrary("glfw", .{ .needed = true });
    // exe_unit_tests.root_module.linkSystemLibrary("GL"); // maybe?
    // exe_unit_tests.root_module.linkSystemLibrary("X11");// idk!
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
