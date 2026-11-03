const std = @import("std");
const modbus = @import("zigot_modbus");
const codec = modbus.modbus_codec;

const Peer = struct {
    pdu: []const u8 = &.{ 3, 2, 0x80, 0x01 },
    unit: u8 = 1,
    corrupt: bool = false,
    calls: usize = 0,
    failure: ?anyerror = null,
    size: ?usize = null,
    request: [256]u8 = undefined,
    request_len: usize = 0,

    fn exchange(ctx: *anyopaque, request: []const u8, response: []u8) !usize {
        const self: *Peer = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        _ = try codec.decode_rtu_frame(request);
        @memcpy(self.request[0..request.len], request);
        self.request_len = request.len;
        if (self.failure) |err| return err;
        if (self.size) |size| return size;
        const n = try codec.encode_rtu_frame(self.unit, self.pdu, response);
        if (self.corrupt) response[n - 1] ^= 1;
        return n;
    }

    fn client(self: *Peer) modbus.SyncRtuModbusClient {
        return .init(.{ .context = self, .exchange = exchange });
    }
};

test "RTU reads validate CRC, unit, function, byte counts and preserve output on errors" {
    var peer: Peer = .{};
    var client = peer.client();
    var out: [2]u16 = @splat(0xdead);
    try std.testing.expectEqual(@as(usize, 1), try client.readHoldingRegister(0, 1, 1, &out));
    try std.testing.expectEqual(@as(u16, 0x8001), out[0]);
    try std.testing.expectEqual(@as(u16, 0xdead), out[1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 0, 0, 0, 1, 0x84, 0x0a }, peer.request[0..peer.request_len]);
    out = @splat(0xdead);
    peer.corrupt = true;
    try std.testing.expectError(error.InvalidCrc, client.readHoldingRegister(0, 1, 1, &out));
    peer.corrupt = false;
    peer.unit = 2;
    try std.testing.expectError(error.UnitIdMismatch, client.readHoldingRegister(0, 1, 1, &out));
    peer.unit = 1;
    peer.pdu = &.{ 4, 2, 0, 1 };
    try std.testing.expectError(error.InvalidFunctionCode, client.readHoldingRegister(0, 1, 1, &out));
    peer.pdu = &.{ 3, 4, 0, 1, 0, 2 };
    try std.testing.expectError(error.InvalidByteCount, client.readHoldingRegister(0, 1, 1, &out));
    peer.pdu = &.{ 3, 2, 0 };
    try std.testing.expectError(error.InvalidLength, client.readHoldingRegister(0, 1, 1, &out));
    peer.pdu = &.{3};
    try std.testing.expectError(error.InvalidLength, client.readHoldingRegister(0, 1, 1, &out));
    peer.size = 257;
    try std.testing.expectError(error.ResponseTooLarge, client.readHoldingRegister(0, 1, 1, &out));
    peer.size = 0;
    try std.testing.expectError(error.InvalidLength, client.readHoldingRegister(0, 1, 1, &out));
    peer.size = null;
    peer.failure = error.Timeout;
    try std.testing.expectError(error.Timeout, client.readHoldingRegister(0, 1, 1, &out));
    try std.testing.expectEqualSlices(u16, &.{ 0xdead, 0xdead }, &out);
}

test "RTU validation rejects invalid and broadcast requests before I/O" {
    var peer: Peer = .{};
    var client = peer.client();
    var out: [2]u16 = undefined;
    try std.testing.expectError(error.InvalidUnitId, client.readHoldingRegister(0, 1, 0, &out));
    try std.testing.expectError(error.InvalidUnitId, client.writeSingleCoil(0, true, 248));
    try std.testing.expectError(error.InvalidQuantity, client.readHoldingRegister(0, 0, 1, &out));
    try std.testing.expectError(error.InvalidQuantity, client.readHoldingRegister(0, 126, 1, &out));
    try std.testing.expectError(error.BufferTooSmall, client.readHoldingRegister(0, 2, 1, out[0..1]));
    try std.testing.expectError(error.InvalidAddressRange, client.readHoldingRegister(65535, 2, 1, &out));
    try std.testing.expectError(error.InvalidQuantity, client.writeMultipleRegisters(0, &.{}, 1));
    try std.testing.expectError(error.InvalidUnitId, client.writeSingleRegister(0, 1, 0));
    try std.testing.expectEqual(@as(usize, 0), peer.calls);
}

test "RTU exceptions preserve actual RTU frame and allow subsequent transactions" {
    var peer: Peer = .{ .pdu = &.{ 0x83, 2 } };
    var client = peer.client();
    var out: [1]u16 = undefined;
    const result = try client.readHoldingRegisterDetailed(0, 1, 1, &out);
    try std.testing.expectEqual(codec.ExceptionCode.illegal_data_address, result.exception.exception_code);
    try std.testing.expectEqual(@as(u8, 3), result.exception.function_code);
    const frame = try codec.decode_rtu_frame(&result.exception.raw_frame);
    try std.testing.expectEqualSlices(u8, peer.pdu, frame.pdu);
    try std.testing.expectError(error.ModbusException, client.readHoldingRegister(0, 1, 1, &out));
    peer.pdu = &.{ 0x84, 2 };
    try std.testing.expectError(error.InvalidFunctionCode, client.readHoldingRegister(0, 1, 1, &out));
    peer.pdu = &.{ 0x83, 2, 0 };
    try std.testing.expectError(error.InvalidLength, client.readHoldingRegister(0, 1, 1, &out));
    peer.pdu = &.{ 3, 2, 0, 42 };
    try std.testing.expectEqual(@as(usize, 1), try client.readHoldingRegister(0, 1, 1, &out));
    try std.testing.expectEqual(@as(u16, 42), out[0]);
}

test "RTU write echoes checked and transport failures never retried" {
    var peer: Peer = .{ .pdu = &.{ 6, 0, 7, 0x80, 0 } };
    var client = peer.client();
    try std.testing.expectEqual(@as(usize, 1), try client.writeSingleRegister(7, 0x8000, 1));
    try std.testing.expectError(error.WriteEchoMismatch, client.writeSingleRegister(7, 0x8001, 1));
    peer.failure = error.Timeout;
    const calls = peer.calls;
    try std.testing.expectError(error.Timeout, client.writeMultipleCoils(0, &.{ true, false }, 1));
    try std.testing.expectEqual(calls + 1, peer.calls);
}
