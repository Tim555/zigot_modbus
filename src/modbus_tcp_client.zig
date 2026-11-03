const std = @import("std");
const codec = @import("modbus_codec.zig");
const TcpClient = @import("tcp_transport.zig").TcpClient;

/// Maximum registers per FC03/FC04 request.
pub const max_register_count: usize = 125;
/// Maximum bits per FC01/FC02 request.
pub const max_bit_count: usize = 2000;

/// Successful element count or the server exception, including its raw frame.
pub const ReadResult = union(enum) {
    count: usize,
    exception: codec.ModbusException,
};

/// Acknowledged element count or the complete server exception.
pub const WriteResult = ReadResult;

/// Blocking Modbus TCP client with caller-owned output buffers.
/// Read addresses are zero-based wire offsets, not 3xxxx/4xxxx reference numbers.
/// Reads write only out[0..quantity] on success; the remaining elements are untouched.
/// Owns its transport: do not copy a connected client or issue concurrent requests.
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

    /// Read 1–125 holding registers (FC03) in ascending address order.
    /// Requires out.len >= quantity; server exceptions become error.ModbusException.
    pub fn readHoldingRegister(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8, out: []u16) !usize {
        return switch (try self.readHoldingRegisterDetailed(address, quantity, unit_id, out)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    /// Same read and buffer contract, preserving the server exception in ReadResult.
    pub fn readHoldingRegisterDetailed(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8, out: []u16) !ReadResult {
        return self.readDetailed(0x03, address, quantity, unit_id, out);
    }

    /// Read 1–125 input registers (FC04) in ascending address order.
    /// Requires out.len >= quantity; server exceptions become error.ModbusException.
    pub fn readInputRegister(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8, out: []u16) !usize {
        return switch (try self.readInputRegisterDetailed(address, quantity, unit_id, out)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    /// Same read and buffer contract, preserving the server exception in ReadResult.
    pub fn readInputRegisterDetailed(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8, out: []u16) !ReadResult {
        return self.readDetailed(4, address, quantity, unit_id, out);
    }

    /// Read 1–2000 coils (FC01) in ascending address order.
    /// Requires out.len >= quantity; server exceptions become error.ModbusException.
    pub fn readCoils(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8, out: []bool) !usize {
        return switch (try self.readCoilsDetailed(address, quantity, unit_id, out)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    /// Same read and buffer contract, preserving the server exception in ReadResult.
    pub fn readCoilsDetailed(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8, out: []bool) !ReadResult {
        return self.readDetailed(1, address, quantity, unit_id, out);
    }

    /// Read 1–2000 discrete inputs (FC02) in ascending address order.
    /// Requires out.len >= quantity; server exceptions become error.ModbusException.
    pub fn readDiscreteInputs(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8, out: []bool) !usize {
        return switch (try self.readDiscreteInputsDetailed(address, quantity, unit_id, out)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    /// Same read and buffer contract, preserving the server exception in ReadResult.
    pub fn readDiscreteInputsDetailed(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8, out: []bool) !ReadResult {
        return self.readDetailed(2, address, quantity, unit_id, out);
    }

    // FC01/02 unpack bits into bools; FC03/04 decode big-endian u16 registers.
    fn readDetailed(self: *SyncTcpModbusClient, comptime function: u8, address: u16, quantity: u16, unit_id: u8, out: []if (function <= 2) bool else u16) !ReadResult {
        if (!self.isConnected()) return error.NotConnected;
        if (quantity == 0 or quantity > (if (function <= 2) max_bit_count else max_register_count)) return error.InvalidQuantity;
        if (out.len < quantity) return error.BufferTooSmall;

        const request_id = self.transaction_id();
        var request: [codec.mbap_header_length + 5]u8 = undefined;
        const request_len = try switch (function) {
            1 => codec.encode_read_coils_request(request_id, unit_id, address, quantity, &request),
            2 => codec.encode_read_discrete_inputs_request(request_id, unit_id, address, quantity, &request),
            3 => codec.encode_read_holding_registers_request(request_id, unit_id, address, quantity, &request),
            4 => codec.encode_read_input_registers_request(request_id, unit_id, address, quantity, &request),
            else => unreachable,
        };
        var response: [codec.max_adu_length]u8 = undefined;
        const response_len = try self.exchange(request[0..request_len], request_id, unit_id, &response);
        const frame = response[0..response_len];
        const function_code = frame[7];
        if ((function_code & 0x80) != 0) {
            const exc = try codec.decode_exception_response(frame, request_id, unit_id);
            if (exc.function_code != function) return error.InvalidFunctionCode;
            return .{ .exception = exc };
        }
        // Reject short/extra data before writing to the caller's buffer.
        const expected_bytes = if (function <= 2) (@as(usize, quantity) + 7) / 8 else @as(usize, quantity) * 2;
        if (function_code != function) return error.InvalidFunctionCode;
        if (frame[8] != expected_bytes) return error.InvalidByteCount;
        const count = try switch (function) {
            1 => codec.decode_read_coils_response(frame, request_id, unit_id, quantity, out),
            2 => codec.decode_read_discrete_inputs_response(frame, request_id, unit_id, quantity, out),
            3 => codec.decode_read_holding_registers_response(frame, request_id, unit_id, out),
            4 => codec.decode_read_input_registers_response(frame, request_id, unit_id, out),
            else => unreachable,
        };
        return .{ .count = count };
    }

    /// Write one coil (FC05) at a zero-based wire address.
    /// Returns the acknowledged count; server exceptions become error.ModbusException.
    /// Writes are never retried automatically: an I/O failure may follow a completed write.
    pub fn writeSingleCoil(self: *SyncTcpModbusClient, address: u16, value: bool, unit_id: u8) !usize {
        return switch (try self.writeSingleCoilDetailed(address, value, unit_id)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    /// Same write contract, preserving the server exception in WriteResult.
    pub fn writeSingleCoilDetailed(self: *SyncTcpModbusClient, address: u16, value: bool, unit_id: u8) !WriteResult {
        if (!self.isConnected()) return error.NotConnected;
        var request: [codec.max_adu_length]u8 = undefined;
        const request_len = try codec.encode_write_single_coil_request(self._transaction_id, unit_id, address, value, &request);
        return self.writeDetailed(request[0..request_len], unit_id);
    }

    /// Write one holding register (FC06) at a zero-based wire address.
    /// Returns the acknowledged count; server exceptions become error.ModbusException.
    /// Writes are never retried automatically: an I/O failure may follow a completed write.
    pub fn writeSingleRegister(self: *SyncTcpModbusClient, address: u16, value: u16, unit_id: u8) !usize {
        return switch (try self.writeSingleRegisterDetailed(address, value, unit_id)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    /// Same write contract, preserving the server exception in WriteResult.
    pub fn writeSingleRegisterDetailed(self: *SyncTcpModbusClient, address: u16, value: u16, unit_id: u8) !WriteResult {
        if (!self.isConnected()) return error.NotConnected;
        var request: [codec.max_adu_length]u8 = undefined;
        const request_len = try codec.encode_write_single_register_request(self._transaction_id, unit_id, address, value, &request);
        return self.writeDetailed(request[0..request_len], unit_id);
    }

    /// Write 1–1968 coils (FC15) at a zero-based wire address.
    /// Returns the acknowledged count; server exceptions become error.ModbusException.
    /// Writes are never retried automatically: an I/O failure may follow a completed write.
    pub fn writeMultipleCoils(self: *SyncTcpModbusClient, address: u16, values: []const bool, unit_id: u8) !usize {
        return switch (try self.writeMultipleCoilsDetailed(address, values, unit_id)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    /// Same write contract, preserving the server exception in WriteResult.
    pub fn writeMultipleCoilsDetailed(self: *SyncTcpModbusClient, address: u16, values: []const bool, unit_id: u8) !WriteResult {
        if (!self.isConnected()) return error.NotConnected;
        var request: [codec.max_adu_length]u8 = undefined;
        const request_len = try codec.encode_write_multiple_coils_request(self._transaction_id, unit_id, address, values, &request);
        return self.writeDetailed(request[0..request_len], unit_id);
    }

    /// Write 1–123 holding registers (FC16) at a zero-based wire address.
    /// Returns the acknowledged count; server exceptions become error.ModbusException.
    /// Writes are never retried automatically: an I/O failure may follow a completed write.
    pub fn writeMultipleRegisters(self: *SyncTcpModbusClient, address: u16, values: []const u16, unit_id: u8) !usize {
        return switch (try self.writeMultipleRegistersDetailed(address, values, unit_id)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    /// Same write contract, preserving the server exception in WriteResult.
    pub fn writeMultipleRegistersDetailed(self: *SyncTcpModbusClient, address: u16, values: []const u16, unit_id: u8) !WriteResult {
        if (!self.isConnected()) return error.NotConnected;
        var request: [codec.max_adu_length]u8 = undefined;
        const request_len = try codec.encode_write_multiple_registers_request(self._transaction_id, unit_id, address, values, &request);
        return self.writeDetailed(request[0..request_len], unit_id);
    }

    fn writeDetailed(self: *SyncTcpModbusClient, request: []const u8, unit_id: u8) !WriteResult {
        const request_id = self.transaction_id();
        var response: [codec.max_adu_length]u8 = undefined;
        const response_len = try self.exchange(request, request_id, unit_id, &response);
        const frame = response[0..response_len];
        const function = request[7];
        if ((frame[7] & 0x80) != 0) {
            const exception = try codec.decode_exception_response(frame, request_id, unit_id);
            if (exception.function_code != function) return error.InvalidFunctionCode;
            return .{ .exception = exception };
        }
        const address = (@as(u16, request[8]) << 8) | request[9];
        const value = (@as(u16, request[10]) << 8) | request[11];
        const count = try switch (function) {
            5 => codec.decode_write_single_coil_response(frame, request_id, unit_id, address, value != 0),
            6 => codec.decode_write_single_register_response(frame, request_id, unit_id, address, value),
            15 => codec.decode_write_multiple_coils_response(frame, request_id, unit_id, address, value),
            16 => codec.decode_write_multiple_registers_response(frame, request_id, unit_id, address, value),
            else => unreachable,
        };
        return .{ .count = count };
    }

    // Receive one complete ADU into caller-owned storage after sending the request.
    fn exchange(self: *SyncTcpModbusClient, request: []const u8, request_id: u16, unit_id: u8, response: *[codec.max_adu_length]u8) !usize {
        try self.transport.send(request);

        // TCP may split a frame across reads; first obtain the complete fixed header.
        var response_header: [codec.mbap_header_length]u8 = undefined;
        try self.transport.receiveExact(&response_header);

        const mbap_header = try codec.decode_mbap_header(&response_header);
        if (mbap_header.transaction_id != request_id) return error.TransactionIdMismatch;
        if (mbap_header.protocol_id != 0) return error.InvalidProtocolId;
        if (mbap_header.unit_id != unit_id) return error.UnitIdMismatch;
        if (mbap_header.length < 3) return error.InvalidLength;

        // MBAP length includes the unit ID already consumed in the seven-byte header.
        const payload_length: usize = @as(usize, mbap_header.length) - 1;
        if (payload_length > codec.max_adu_length - codec.mbap_header_length) return error.ResponseTooLarge;

        std.mem.copyForwards(u8, response[0..codec.mbap_header_length], &response_header);
        try self.transport.receiveExact(response[codec.mbap_header_length .. codec.mbap_header_length + payload_length]);

        return codec.mbap_header_length + payload_length;
    }

    fn transaction_id(self: *SyncTcpModbusClient) u16 {
        const id = self._transaction_id;
        self._transaction_id +%= 1;
        return id;
    }
};

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
    try std.testing.expectEqual(@as(codec.ExceptionCode, .illegal_data_address), result.exception.exception_code);
    try std.testing.expectEqual(@as(u16, 0x1234), result.exception.transaction_id);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x83, 0x02 }, result.exception.pdu[0..result.exception.pdu_len]);
}
