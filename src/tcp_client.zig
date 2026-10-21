const std = @import("std");
const tcp = @import("tcp.zig");

pub const max_register_count: usize = 125;

fn readExact(stream: std.net.Stream, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const n = try stream.read(buffer[offset..]);
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}

// Modbus TCP client with caller-owned buffers and explicit protocol validation.
const SyncTcpModbusClient = struct {
    connection: std.net.Stream,
    _connected: bool = false,
    _transaction_id: u16 = 0,

    pub fn connect(self: *SyncTcpModbusClient, host: []const u8, port: u16) !void {
        const address = try std.net.Address.parseIp4(host, port);
        self.connection = try std.net.tcpConnectToAddress(address);
        self._connected = true;
    }

    pub fn disconnect(self: *SyncTcpModbusClient) void {
        if (self._connected) {
            self.connection.close();
            self._connected = false;
        }
    }

    pub fn isConnected(self: *SyncTcpModbusClient) bool {
        return self._connected;
    }

    pub fn readHoldingRegister(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8, out: []u16) !usize {
        if (!self._connected) return error.NotConnected;
        if (quantity == 0 or quantity > max_register_count) return error.InvalidQuantity;
        if (out.len < quantity) return error.BufferTooSmall;

        const request_id = self.transaction_id();
        var request: [tcp.mbap_header_length + 5]u8 = undefined;
        const request_len = try tcp.encode_read_holding_registers_request(request_id, unit_id, address, quantity, &request);
        try self.connection.writeAll(request[0..request_len]);

        var response_header: [tcp.mbap_header_length]u8 = undefined;
        try readExact(self.connection, &response_header);

        const mbap_header = try tcp.decode_mbap_header(&response_header);
        if (mbap_header.transaction_id != request_id) return error.TransactionIdMismatch;
        if (mbap_header.protocol_id != 0) return error.InvalidProtocolId;
        if (mbap_header.unit_id != unit_id) return error.UnitIdMismatch;
        if (mbap_header.length < 3) return error.InvalidLength;

        const payload_length: usize = @as(usize, mbap_header.length) - 1;
        if (payload_length > tcp.max_adu_length - tcp.mbap_header_length) return error.ResponseTooLarge;

        var response: [tcp.max_adu_length]u8 = undefined;
        std.mem.copyForwards(u8, response[0..tcp.mbap_header_length], &response_header);
        try readExact(self.connection, response[tcp.mbap_header_length .. tcp.mbap_header_length + payload_length]);

        return try tcp.decode_read_holding_registers_response(response[0 .. tcp.mbap_header_length + payload_length], request_id, unit_id, out);
    }

    fn transaction_id(self: *SyncTcpModbusClient) u16 {
        const id = self._transaction_id;
        self._transaction_id +%= 1;
        return id;
    }
};

test "transaction_id wraps correctly" {
    var client = SyncTcpModbusClient{
        .connection = undefined,
        ._connected = false,
        ._transaction_id = 0xffff,
    };
    const id1 = client.transaction_id();
    const id2 = client.transaction_id();
    try std.testing.expect(id1 == 0xffff);
    try std.testing.expect(id2 == 0);
}
