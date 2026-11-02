const std = @import("std");
const tcp = @import("tcp.zig");
const TcpClient = @import("tcp_transport.zig").TcpClient;

pub const max_register_count: usize = 125;
pub const max_bit_count: usize = 2000;

pub const ReadResult = union(enum) {
    count: usize,
    exception: tcp.ModbusException,
};

pub const ReadHoldingRegisterResult = ReadResult;
pub const ReadInputRegisterResult = ReadResult;
pub const ReadCoilsResult = ReadResult;
pub const ReadDiscreteInputsResult = ReadResult;

// Modbus TCP client with caller-owned buffers and explicit protocol validation.
pub const SyncTcpModbusClient = struct {
    transport: TcpClient,
    _transaction_id: u16 = 0,
    /// The caller-owned Io backend must outlive the client.
    pub fn init(io: std.Io) SyncTcpModbusClient {
        return .{ .transport = TcpClient.init(io) };
    }

    pub fn connect(self: *SyncTcpModbusClient, host: []const u8, port: u16) !void {
        try self.transport.connect(host, port);
    }

    pub fn disconnect(self: *SyncTcpModbusClient) void {
        self.transport.disconnect();
    }

    pub fn isConnected(self: *const SyncTcpModbusClient) bool {
        return self.transport.isConnected();
    }

    pub fn readHoldingRegister(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8, out: []u16) !usize {
        return switch (try self.readHoldingRegisterDetailed(address, quantity, unit_id, out)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    pub fn readHoldingRegisterDetailed(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8, out: []u16) !ReadResult {
        return self.readDetailed(0x03, address, quantity, unit_id, out);
    }

    pub fn readInputRegister(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8, out: []u16) !usize {
        return switch (try self.readInputRegisterDetailed(address, quantity, unit_id, out)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    pub fn readInputRegisterDetailed(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8, out: []u16) !ReadResult {
        return self.readDetailed(4, address, quantity, unit_id, out);
    }

    pub fn readCoils(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8, out: []bool) !usize {
        return switch (try self.readCoilsDetailed(address, quantity, unit_id, out)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    pub fn readCoilsDetailed(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8, out: []bool) !ReadResult {
        return self.readDetailed(1, address, quantity, unit_id, out);
    }

    pub fn readDiscreteInputs(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8, out: []bool) !usize {
        return switch (try self.readDiscreteInputsDetailed(address, quantity, unit_id, out)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    pub fn readDiscreteInputsDetailed(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8, out: []bool) !ReadResult {
        return self.readDetailed(2, address, quantity, unit_id, out);
    }

    fn readDetailed(self: *SyncTcpModbusClient, comptime function: u8, address: u16, quantity: u16, unit_id: u8, out: []if (function <= 2) bool else u16) !ReadResult {
        if (!self.isConnected()) return error.NotConnected;
        if (quantity == 0 or quantity > (if (function <= 2) max_bit_count else max_register_count)) return error.InvalidQuantity;
        if (out.len < quantity) return error.BufferTooSmall;

        const request_id = self.transaction_id();
        var request: [tcp.mbap_header_length + 5]u8 = undefined;
        const request_len = try switch (function) {
            1 => tcp.encode_read_coils_request(request_id, unit_id, address, quantity, &request),
            2 => tcp.encode_read_discrete_inputs_request(request_id, unit_id, address, quantity, &request),
            3 => tcp.encode_read_holding_registers_request(request_id, unit_id, address, quantity, &request),
            4 => tcp.encode_read_input_registers_request(request_id, unit_id, address, quantity, &request),
            else => unreachable,
        };
        try self.transport.send(request[0..request_len]);

        var response_header: [tcp.mbap_header_length]u8 = undefined;
        try self.transport.receiveExact(&response_header);

        const mbap_header = try tcp.decode_mbap_header(&response_header);
        if (mbap_header.transaction_id != request_id) return error.TransactionIdMismatch;
        if (mbap_header.protocol_id != 0) return error.InvalidProtocolId;
        if (mbap_header.unit_id != unit_id) return error.UnitIdMismatch;
        if (mbap_header.length < 3) return error.InvalidLength;

        const payload_length: usize = @as(usize, mbap_header.length) - 1;
        if (payload_length > tcp.max_adu_length - tcp.mbap_header_length) return error.ResponseTooLarge;

        var response: [tcp.max_adu_length]u8 = undefined;
        std.mem.copyForwards(u8, response[0..tcp.mbap_header_length], &response_header);
        try self.transport.receiveExact(response[tcp.mbap_header_length .. tcp.mbap_header_length + payload_length]);

        const frame = response[0 .. tcp.mbap_header_length + payload_length];
        const function_code = frame[7];
        if ((function_code & 0x80) != 0) {
            const exc = try tcp.decode_exception_response(frame, request_id, unit_id);
            if (exc.function_code != function) return error.InvalidFunctionCode;
            return .{ .exception = exc };
        }
        const expected_bytes = if (function <= 2) (@as(usize, quantity) + 7) / 8 else @as(usize, quantity) * 2;
        if (function_code != function) return error.InvalidFunctionCode;
        if (frame[8] != expected_bytes) return error.InvalidByteCount;
        const count = try switch (function) {
            1 => tcp.decode_read_coils_response(frame, request_id, unit_id, quantity, out),
            2 => tcp.decode_read_discrete_inputs_response(frame, request_id, unit_id, quantity, out),
            3 => tcp.decode_read_holding_registers_response(frame, request_id, unit_id, out),
            4 => tcp.decode_read_input_registers_response(frame, request_id, unit_id, out),
            else => unreachable,
        };
        return .{ .count = count };
    }

    fn transaction_id(self: *SyncTcpModbusClient) u16 {
        const id = self._transaction_id;
        self._transaction_id +%= 1;
        return id;
    }
};

pub const TcpModbusClient = SyncTcpModbusClient;

test "transaction_id wraps correctly" {
    var client = SyncTcpModbusClient.init(std.testing.io);
    client._transaction_id = 0xffff;
    const id1 = client.transaction_id();
    const id2 = client.transaction_id();
    try std.testing.expect(id1 == 0xffff);
    try std.testing.expect(id2 == 0);
}

test "readHoldingRegisterDetailed preserves modbus exception payload" {
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var client = SyncTcpModbusClient.init(io);
    client._transaction_id = 0x1234;
    defer client.disconnect();
    try client.connect("127.0.0.1", server.socket.address.getPort());
    const peer = try server.accept(io);
    defer peer.close(io);

    const response = [_]u8{ 0x12, 0x34, 0x00, 0x00, 0x00, 0x03, 0x01, 0x83, 0x02 };
    var writer = peer.writer(io, &.{});
    try writer.interface.writeAll(&response);

    var registers: [2]u16 = undefined;
    const result = try client.readHoldingRegisterDetailed(14, 2, 1, &registers);

    try std.testing.expectEqual(@as(u8, 0x03), result.exception.function_code);
    try std.testing.expectEqual(@as(tcp.ExceptionCode, .illegal_data_address), result.exception.exception_code);
    try std.testing.expectEqual(@as(u16, 0x1234), result.exception.transaction_id);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x83, 0x02 }, result.exception.pdu[0..result.exception.pdu_len]);
}
