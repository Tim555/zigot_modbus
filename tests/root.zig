const std = @import("std");
const zigot_modbus = @import("zigot_modbus");

test "public API: RTU read holding registers request checksum" {
    // Unit 1, function 3, starting address 0, quantity 10.
    const request = [_]u8{ 0x01, 0x03, 0x00, 0x00, 0x00, 0x0a };
    try std.testing.expectEqual(@as(u16, 0xcdc5), zigot_modbus.rtu.crc16(&request));
}

test "public API: protocol constants" {
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(zigot_modbus.FunctionCode.read_holding_registers));
    try std.testing.expectEqual(@as(u16, 502), zigot_modbus.tcp.default_port);
    try std.testing.expectEqual(@as(usize, 260), zigot_modbus.tcp.max_adu_length);
}
