const std = @import("std");

// Modbus TCP constants. MBAP encoding, decoding, and transport are future work.
pub const default_port: u16 = 502;
pub const mbap_header_length: usize = 7;
pub const max_adu_length: usize = 260;

// Modbus TCP Client struct to handle connection.
const SyncTcpModbusClient = struct {
    connection: std.net.StreamingSocket,
    _connected: bool = false,
    _transaction_id: u16 = 0,

    pub fn connect(self: *SyncTcpModbusClient, host: []const u8, port: u16) !void {
        const address = try std.net.Address.parseIp4(host, port);
        self.connection = try std.net.StreamingSocket.connect(address);
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

    pub fn readHoldingRegister(self: *SyncTcpModbusClient, address: u16, quantity: u16, unit_id: u8) ![]u16 {
        const header = build_mbap_header(self.transaction_id(), 0, 6, unit_id);
        const pdu = try build_mbap_pdu_read_holding_register(address, quantity);
        const adu = try std.heap.page_allocator.alloc(u8, header.len + pdu.len);
        std.mem.copyForwards(u8, adu[0..header.len], header);
        std.mem.copyForwards(u8, adu[header.len..], pdu);
        try self.connection.writeAll(adu);
        std.heap.page_allocator.free(adu);
        std.heap.page_allocator.free(pdu);
        const response_header = try std.heap.page_allocator.alloc(u8, mbap_header_length);
        try self.connection.readAll(response_header);
        std.heap.page_allocator.free(response_header);
        return error.NotImplemented;
    }

    fn transaction_id(self: *SyncTcpModbusClient) u16 {
        const id = self._transaction_id;
        self._transaction_id += 1;
        return id;
    }
};

fn build_mbap_header(transaction_id: u16, protocol_id: u16, length: u16, unit_id: u8) [7]u8 {
    const header = [7]u8{
        @as(u8, @intCast(transaction_id >> 8)),
        @as(u8, @intCast(transaction_id & 0xFF)),
        @as(u8, @intCast(protocol_id >> 8)),
        @as(u8, @intCast(protocol_id & 0xFF)),
        @as(u8, @intCast(length >> 8)),
        @as(u8, @intCast(length & 0xFF)),
        unit_id,
    };
    return header;
}

fn build_mbap_pdu(function_code: u8, data: []const u8) ![]u8 {
    var pdu = try std.heap.page_allocator.alloc(u8, data.len + 1);
    pdu[0] = function_code;
    std.mem.copyForwards(u8, pdu[1..], data);
    return pdu;
}

fn build_mbap_pdu_read_holding_register(address: u16, quantity: u16) ![]u8 {
    const data = [_]u8{
        @as(u8, @intCast(address >> 8)),
        @as(u8, @intCast(address & 0xFF)),
        @as(u8, @intCast(quantity >> 8)),
        @as(u8, @intCast(quantity & 0xFF)),
    };
    return build_mbap_pdu(3, &data);
}

test "build_mbap_pdu_read_holding_register" {
    const pdu = try build_mbap_pdu_read_holding_register(0x1234, 0x5678);
    defer std.heap.page_allocator.free(pdu);
    try std.testing.expect(pdu[0] == 3);
    try std.testing.expect(pdu[1] == 0x12);
    try std.testing.expect(pdu[2] == 0x34);
    try std.testing.expect(pdu[3] == 0x56);
    try std.testing.expect(pdu[4] == 0x78);
}

test "build_mbap_header" {
    const header = build_mbap_header(0x1234, 0x5678, 0x9ABC, 0xDE);
    try std.testing.expect(header[0] == 0x12);
    try std.testing.expect(header[1] == 0x34);
    try std.testing.expect(header[2] == 0x56);
    try std.testing.expect(header[3] == 0x78);
    try std.testing.expect(header[4] == 0x9A);
    try std.testing.expect(header[5] == 0xBC);
    try std.testing.expect(header[6] == 0xDE);
}
