//! Loopback fixture for test_server/server_interop.py; port is reported on stderr.
const std = @import("std");
const modbus = @import("zigot_modbus");

pub fn main(init: std.process.Init) !void {
    var coils: [2][4096]bool = @splat(@splat(false));
    var holding: [2][4096]u16 = @splat(@splat(0));
    const inputs: [4096]u16 = @splat(0x1234);
    const discrete: [4096]bool = @splat(true);
    const devices = [_]modbus.Device{
        .{ .unit_id = 1, .coils = &coils[0], .holding_registers = &holding[0], .input_registers = &inputs, .discrete_inputs = &discrete },
        .{ .unit_id = 7, .coils = &coils[1], .holding_registers = &holding[1], .input_registers = &inputs, .discrete_inputs = &discrete },
    };
    var server = try modbus.TcpServer.init(init.io, "127.0.0.1", 0, &devices, .{});
    defer server.deinit();
    std.debug.print("{d}\n", .{server.port()});
    try server.serve();
}
