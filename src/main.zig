const std = @import("std");
const zigot_modbus = @import("zigot_modbus");

pub fn main(init: std.process.Init) !void {
    var client = zigot_modbus.SyncTcpModbusClient.init(init.io);
    defer client.disconnect();

    std.debug.print("Modbus TCP client initialized. Connect to a server with connect(host, port).\n", .{});
    std.debug.print("Status: connected={}\n", .{client.isConnected()});

    client.connect("127.0.0.1", 5020) catch |err| {
        std.debug.print("Failed to connect: {}\n", .{err});
        return err;
    };
    std.debug.print("Status: connected={}\n", .{client.isConnected()});

    var result: [2]u16 = undefined;
    const count = client.readHoldingRegister(10, 2, 1, &result) catch |err| {
        std.debug.print("Failed to read holding registers: {}\n", .{err});
        return err;
    };
    std.debug.print("Read {} holding registers: {any}\n", .{ count, result[0..count] });
    client.disconnect();
    std.debug.print("Status: connected={}\n", .{client.isConnected()});
}
