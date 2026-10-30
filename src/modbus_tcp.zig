const std = @import("std");
const tcp = @import("tcp.zig");
const TcpClient = @import("tcp_transport.zig").TcpClient;

pub const max_register_count: usize = 125;

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
        if (!self.isConnected()) return error.NotConnected;
        if (quantity == 0 or quantity > max_register_count) return error.InvalidQuantity;
        if (out.len < quantity) return error.BufferTooSmall;

        const request_id = self.transaction_id();
        var request: [tcp.mbap_header_length + 5]u8 = undefined;
        const request_len = try tcp.encode_read_holding_registers_request(request_id, unit_id, address, quantity, &request);
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

        return try tcp.decode_read_holding_registers_response(response[0 .. tcp.mbap_header_length + payload_length], request_id, unit_id, out);
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
