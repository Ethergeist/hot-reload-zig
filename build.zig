const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared plugin struct module - imported by both host and plugins
    const mod_plugin = b.addModule("plugin", .{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
    });

    // plugin-test dynamic library
    const lib_plugin_test = b.addLibrary(.{
        .name = "plugin-test",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/plugin-test/plugin.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
            .imports = &.{
                .{ .name = "plugin", .module = mod_plugin },
            },
        }),
    });
    lib_plugin_test.root_module.link_libc = true;

    const install_plugin_test = b.addInstallFileWithDir(
        lib_plugin_test.getEmittedBin(),
        .{ .custom = "../plugins" },
        "plugin-test.plg",
    );
    install_plugin_test.step.dependOn(&lib_plugin_test.step);
    b.getInstallStep().dependOn(&install_plugin_test.step);

    // Host executable
    const exe = b.addExecutable(.{
        .name = "hot-reload",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plugin", .module = mod_plugin },
            },
        }),
    });
    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the host");
    run_step.dependOn(&install_plugin_test.step);
    run_step.dependOn(&run_cmd.step);
}
