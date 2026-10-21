//! Modbus RTU primitives; framing and serial transport are future work.
const std = @import("std");

/// CRC-16/MODBUS. RTU frames transmit the low byte first.
pub fn crc16(bytes: []const u8) u16 {
    var crc: u16 = 0xffff;
    for (bytes) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            crc = if (crc & 1 != 0) (crc >> 1) ^ 0xa001 else crc >> 1;
        }
    }
    return crc;
}

test "CRC-16/MODBUS check value" {
    try std.testing.expectEqual(@as(u16, 0x4b37), crc16("123456789"));
    try std.testing.expectEqual(@as(u16, 0xffff), crc16(""));
}
