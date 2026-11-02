const std = @import("std");
const modbus = @import("zigot_modbus");

fn write(client: *modbus.SyncTcpModbusClient, comptime function: u8, address: u16) !usize {
    return switch (function) {
        5 => client.writeSingleCoil(address, true, 7),
        6 => client.writeSingleRegister(address, 0x8001, 7),
        15 => client.writeMultipleCoils(address, &.{ true, false, true }, 7),
        16 => client.writeMultipleRegisters(address, &.{ 0x8001, 0xffff }, 7),
        else => unreachable,
    };
}

fn writeDetailed(client: *modbus.SyncTcpModbusClient, comptime function: u8) !modbus.modbus_tcp.WriteResult {
    return switch (function) {
        5 => client.writeSingleCoilDetailed(10, true, 7),
        6 => client.writeSingleRegisterDetailed(10, 0x8001, 7),
        15 => client.writeMultipleCoilsDetailed(10, &.{ true, false, true }, 7),
        16 => client.writeMultipleRegistersDetailed(10, &.{ 0x8001, 0xffff }, 7),
        else => unreachable,
    };
}

test "public TCP writes encode requests, validate echoes and retain exceptions" {
    inline for (.{ @as(u8, 5), @as(u8, 6), @as(u8, 15), @as(u8, 16) }) |function| {
        const io = std.testing.io;
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var server = try address.listen(io, .{});
        defer server.deinit(io);
        var client = modbus.SyncTcpModbusClient.init(io);
        defer client.disconnect();
        try std.testing.expectError(error.NotConnected, write(&client, function, 10));
        try client.connect("127.0.0.1", server.socket.address.getPort());
        const peer = try server.accept(io);
        defer peer.close(io);
        var writer = peer.writer(io, &.{});
        const echoed: u16 = switch (function) {
            5 => 0xff00,
            6 => 0x8001,
            15 => 3,
            16 => 2,
            else => unreachable,
        };
        var response = [_]u8{ 0, 0, 0, 0, 0, 6, 7, function, 0, 10, @intCast(echoed >> 8), @truncate(echoed) };
        try writer.interface.writeAll(response[0..4]);
        try writer.interface.writeAll(response[4..]);
        try std.testing.expectEqual(@as(usize, if (function <= 6) 1 else echoed), try write(&client, function, 10));
        const length: usize = switch (function) {
            15 => 14,
            16 => 17,
            else => 12,
        };
        var request: [17]u8 = undefined;
        var offset: usize = 0;
        while (offset < length) {
            var slices = [_][]u8{request[offset..length]};
            const received = try peer.readWithControl(io, &slices, &.{});
            if (received.data_len == 0) return error.EndOfStream;
            offset += received.data_len;
        }
        try std.testing.expectEqualSlices(u8, response[6..12], request[6..12]);
        if (function == 15) try std.testing.expectEqualSlices(u8, &.{ 1, 5 }, request[12..14]);
        if (function == 16) try std.testing.expectEqualSlices(u8, &.{ 4, 0x80, 1, 0xff, 0xff }, request[12..17]);

        const exception = [_]u8{ 0, 1, 0, 0, 0, 3, 7, function | 0x80, 2 };
        try writer.interface.writeAll(&exception);
        const result = try writeDetailed(&client, function);
        try std.testing.expectEqual(function, result.exception.function_code);
        try std.testing.expectEqualSlices(u8, &exception, result.exception.raw_frame[0..result.exception.raw_frame_len]);
        var generic_exception = exception;
        generic_exception[1] = 2;
        try writer.interface.writeAll(&generic_exception);
        try std.testing.expectError(error.ModbusException, write(&client, function, 10));
        response[1] = 3;
        response[11] ^= 1;
        try writer.interface.writeAll(&response);
        try std.testing.expectError(error.WriteEchoMismatch, write(&client, function, 10));
    }
}

test "invalid multiple writes fail before consuming a transaction" {
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var client = modbus.SyncTcpModbusClient.init(io);
    defer client.disconnect();
    try client.connect("127.0.0.1", server.socket.address.getPort());
    const peer = try server.accept(io);
    defer peer.close(io);
    try std.testing.expectError(error.InvalidQuantity, client.writeMultipleCoils(0, &.{}, 1));
    try std.testing.expectError(error.InvalidQuantity, client.writeMultipleRegisters(0, &.{}, 1));
    try std.testing.expectError(error.InvalidAddressRange, client.writeMultipleCoils(65535, &.{ true, false }, 1));
    try std.testing.expectError(error.InvalidAddressRange, client.writeMultipleRegisters(65535, &.{ 1, 2 }, 1));
    try std.testing.expectEqual(@as(u16, 0), client._transaction_id);
}
