const std = @import("std");
const zw = @import("zig_wayland");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = zw.Scanner.create(b, .{});

    const wayland_protocols = b.dependency("wayland_protocols", .{});
    const kde_protocols = b.lazyDependency("kde_protocols", .{});

    const wayland = b.createModule(.{
        .root_source_file = scanner.result,
    });

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addCustomProtocol(wayland_protocols.path("staging/ext-idle-notify/ext-idle-notify-v1.xml"));
    scanner.addCustomProtocol(wayland_protocols.path("staging/xdg-activation/xdg-activation-v1.xml"));
    scanner.addCustomProtocol(kde_protocols.?.path("src/protocols/appmenu.xml"));
    scanner.generate("wl_compositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 4);
    scanner.generate("ext_idle_notifier_v1", 1);
    scanner.generate("xdg_wm_base", 5);
    scanner.generate("xdg_activation_v1", 1);
    if (kde_protocols) |_| {
        scanner.generate("org_kde_kwin_appmenu_manager", 2);
    }

    const exe = b.addExecutable(.{
        .name = "break-reminder",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("wayland", wayland);

    exe.linkLibC();
    exe.linkSystemLibrary2("wayland-client", .{});
    exe.linkSystemLibrary2("dbus-1", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
