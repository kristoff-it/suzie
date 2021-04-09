const std = @import("std");
const deps = @import("deps.zig");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("suziebot", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    if (@hasDecl(deps, "addAllTo")) {
        deps.addAllTo(exe);
    } else {
        deps.pkgs.addAllTo(exe);
    }
    exe.install();

    const main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
