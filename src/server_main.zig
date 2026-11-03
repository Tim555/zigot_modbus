//! Development server for `task run-server` and the client example.
const std = @import("std");
const modbus = @import("zigot_modbus");

pub fn main(init: std.process.Init) !void {
    var coils: [2000]bool = @splat(false);
    var registers: [125]u16 = @splat(0);
    registers[10] = 12;
    registers[11] = 13;
    const devices = [_]modbus.tcp_server.Device{.{
        .unit_id = 1,
        .coils = &coils,
        .holding_registers = &registers,
        .input_registers = &.{ 14, 15 },
        .discrete_inputs = &.{ true, false, true, false },
    }};
    var server = try modbus.TcpServer.init(init.io, "127.0.0.1", 5020, &devices, .{});
    defer server.deinit();
    std.debug.print("Modbus TCP server listening on 127.0.0.1:{d} (unit 1). Press Ctrl+C to stop.\n", .{server.port()});
    try server.serve();
}
