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
    const test_step = b.step("test", "Run unit and public API tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);
    const check = b.step("check", "Compile the library tests without running them");
    check.dependOn(&unit_tests.step);
    check.dependOn(&integration_tests.step);
}
