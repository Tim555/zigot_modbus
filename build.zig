const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zigot_modbus = b.addModule("zigot_modbus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = zigot_modbus });
    const integration_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigot_modbus", .module = zigot_modbus }},
    }) });

    const example_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigot_modbus", .module = zigot_modbus }},
    });
    const example = b.addExecutable(.{
        .name = "zigot_modbus_example",
        .root_module = example_module,
    });
    b.installArtifact(example);

    const test_step = b.step("test", "Run unit and public API tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);
    const check = b.step("check", "Compile the library tests without running them");
    check.dependOn(&unit_tests.step);
    check.dependOn(&integration_tests.step);
    const fuzz_smoke = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/fuzz_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigot_modbus", .module = zigot_modbus }},
    }) });
    const fuzz_step = b.step("fuzz-smoke", "Run bounded deterministic TCP read decoder mutations");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_smoke).step);

    // Opt-in: the Python harness supplies a live loopback server and reference vectors.
    const interop_step = b.step("interop-test", "Run against the PyModbus server (use test_server/interop.py)");
    if (b.option([]const u8, "interop-vectors", "Absolute path to generated PyModbus vectors")) |path| {
        const options = b.addOptions();
        options.addOption(u16, "port", b.option(u16, "interop-port", "Loopback PyModbus server port") orelse 5020);
        const module = b.createModule(.{
            .root_source_file = b.path("tests/interop.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigot_modbus", .module = zigot_modbus }},
        });
        module.addOptions("interop_options", options);
        module.addAnonymousImport("interop_vectors", .{ .root_source_file = .{ .cwd_relative = path } });
        interop_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    } else {
        interop_step.dependOn(&b.addFail("Run test_server/interop.py to start a server and generate interop vectors").step);
    }
}
