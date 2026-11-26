const std = @import("std");
const zigot_modbus = @import("zigot_modbus");

test "public API: RTU read holding registers request checksum" {
    // Unit 1, function 3, starting address 0, quantity 10.
    const request = [_]u8{ 0x01, 0x03, 0x00, 0x00, 0x00, 0x0a };
    try std.testing.expectEqual(@as(u16, 0xcdc5), zigot_modbus.modbus_codec.crc16(&request));
}

test "public API: protocol constants" {
    try std.testing.expectEqual(@as(u8, 3), @backingInt(zigot_modbus.FunctionCode.read_holding_registers));
    try std.testing.expectEqual(@as(u16, 502), zigot_modbus.modbus_codec.default_port);
    try std.testing.expectEqual(@as(usize, 260), zigot_modbus.modbus_codec.max_adu_length);
}

test "public API: disconnected TCP transport rejects I/O" {
    var client = zigot_modbus.TcpClient.init(std.testing.io);
    var buffer: [1]u8 = undefined;
    try std.testing.expect(!client.isConnected());
    try std.testing.expectError(error.NotConnected, client.send("hello"));
    try std.testing.expectError(error.NotConnected, client.receive(&buffer));
    try std.testing.expectError(error.NotConnected, client.receiveExact(&buffer));
    client.disconnect();
    client.disconnect();
}

test "public API: TCP byte stream, EOF, and reconnect" {
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var client = zigot_modbus.TcpClient.init(io);
    defer client.disconnect();
    try client.connect("127.0.0.1", port);
    const peer = try server.accept(io);
    defer peer.close(io);
    try std.testing.expect(client.isConnected());
    try std.testing.expectError(error.AlreadyConnected, client.connect("127.0.0.1", port));

    try client.send(&.{});
    try std.testing.expectEqual(@as(usize, 0), try client.receive(&.{}));
    try client.receiveExact(&.{});
    try std.testing.expect(client.isConnected());

    const bytes = [_]u8{ 0, 255, 1, 128, 42 };
    try client.send(&bytes);
    var received: [bytes.len]u8 = undefined;
    try readPeerExact(peer, &received);
    try std.testing.expectEqualSlices(u8, &bytes, &received);

    var writer = peer.writer(io, &.{});
    try writer.interface.writeAll("ab");
    try writer.interface.writeAll("cdef");
    var first: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try client.receive(&first));
    try std.testing.expectEqualStrings("a", &first);
    var rest: [5]u8 = undefined;
    try client.receiveExact(&rest);
    try std.testing.expectEqualStrings("bcdef", &rest);

    try peer.shutdown(io, .send);
    try std.testing.expectEqual(@as(usize, 0), try client.receive(&first));
    try std.testing.expect(!client.isConnected());
    try client.connect("127.0.0.1", port);
    const second_peer = try server.accept(io);
    defer second_peer.close(io);
    try std.testing.expect(client.isConnected());
    client.disconnect();
    client.disconnect();
    try std.testing.expect(!client.isConnected());
}

test "public API: exact receive reports truncated stream" {
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var client = zigot_modbus.TcpClient.init(io);
    defer client.disconnect();
    try client.connect("127.0.0.1", server.socket.address.getPort());
    const peer = try server.accept(io);
    defer peer.close(io);
    var writer = peer.writer(io, &.{});
    try writer.interface.writeAll("ab");
    try peer.shutdown(io, .send);

    var buffer: [4]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, client.receiveExact(&buffer));
    try std.testing.expectEqualStrings("ab", buffer[0..2]);
    try std.testing.expect(!client.isConnected());
}

test "public API: Modbus read uses the Zig 0.17 transport" {
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var client = zigot_modbus.SyncTcpModbusClient.init(io);
    defer client.disconnect();
    try client.connect("127.0.0.1", server.socket.address.getPort());
    const peer = try server.accept(io);
    defer peer.close(io);

    // Queue a canned response so this small exchange needs no worker thread.
    const response = [_]u8{ 0, 0, 0, 0, 0, 7, 1, 3, 4, 0, 12, 0, 13 };
    var writer = peer.writer(io, &.{});
    try writer.interface.writeAll(&response);
    var registers: [2]u16 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try client.readHoldingRegister(10, 2, 1, &registers));
    try std.testing.expectEqualSlices(u16, &.{ 12, 13 }, &registers);

    var request: [12]u8 = undefined;
    try readPeerExact(peer, &request);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 6, 1, 3, 0, 10, 0, 2 }, &request);
}

fn readPeerExact(peer: std.Io.net.Stream, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        var slices = [_][]u8{buffer[offset..]};
        const result = try peer.readWithControl(std.testing.io, &slices, &.{});
        if (result.data_len == 0) return error.EndOfStream;
        offset += result.data_len;
    }
}

test "TCP receive timeout closes a silent peer connection" {
    var pair = try transportPair(.{ .read_timeout = timeoutMs(25) });
    defer pair.client.disconnect();
    defer pair.peer.close(std.testing.io);
    var buffer: [1]u8 = undefined;
    try std.testing.expectError(error.Timeout, pair.client.receive(&buffer));
    try std.testing.expect(!pair.client.isConnected());
    try std.testing.expectError(error.NotConnected, pair.client.receiveExact(&buffer));
}

test "TCP exact receive times out after a partial response" {
    var pair = try transportPair(.{ .read_timeout = timeoutMs(25) });
    defer pair.client.disconnect();
    defer pair.peer.close(std.testing.io);
    var writer = pair.peer.writer(std.testing.io, &.{});
    try writer.interface.writeAll("ab");
    var buffer: [4]u8 = undefined;
    try std.testing.expectError(error.Timeout, pair.client.receiveExact(&buffer));
    try std.testing.expectEqualStrings("ab", buffer[0..2]);
    try std.testing.expect(!pair.client.isConnected());
}

test "TCP exact receive does not restart its timeout for each fragment" {
    var pair = try transportPair(.{ .read_timeout = timeoutMs(150) });
    defer pair.client.disconnect();
    defer pair.peer.close(std.testing.io);
    const SlowPeer = struct {
        fn send(peer: std.Io.net.Stream) !void {
            var writer = peer.writer(std.testing.io, &.{});
            try writer.interface.writeAll("a");
            try std.Io.sleep(std.testing.io, .fromMilliseconds(100), .awake);
            try writer.interface.writeAll("b");
            try std.Io.sleep(std.testing.io, .fromMilliseconds(100), .awake);
            try writer.interface.writeAll("c");
        }
    };
    var sender = try std.testing.io.concurrent(SlowPeer.send, .{pair.peer});
    defer _ = sender.cancel(std.testing.io) catch {};
    var buffer: [3]u8 = undefined;
    try std.testing.expectError(error.Timeout, pair.client.receiveExact(&buffer));
    try std.testing.expect(!pair.client.isConnected());
}

test "TCP send timeout closes a backpressured connection" {
    var pair = try transportPair(.{});
    defer pair.client.disconnect();
    defer pair.peer.close(std.testing.io);
    // A successful send may only mean the OS buffered the data. Keep filling
    // the unread connection under one deadline instead of assuming a fixed
    // payload exceeds every platform's buffering capacity.
    const bytes = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0x5a);
    pair.client.options.write_timeout = timeoutMs(100).toDeadline(std.testing.io);
    const Sender = struct {
        fn fill(client: *zigot_modbus.TcpClient, data: []const u8) !void {
            while (true) try client.send(data);
        }
    };
    try std.testing.expectError(error.Timeout, Sender.fill(&pair.client, bytes));
    try std.testing.expect(!pair.client.isConnected());
}

test "TCP timeouts can be disabled" {
    var pair = try transportPair(.{
        .connect_timeout = .none,
        .read_timeout = .none,
        .write_timeout = .none,
    });
    defer pair.client.disconnect();
    defer pair.peer.close(std.testing.io);
    try pair.client.send("hi");
    var request: [2]u8 = undefined;
    try readPeerExact(pair.peer, &request);
    try std.testing.expectEqualStrings("hi", &request);
    var writer = pair.peer.writer(std.testing.io, &.{});
    try writer.interface.writeAll("ok");
    var response: [2]u8 = undefined;
    try pair.client.receiveExact(&response);
    try std.testing.expectEqualStrings("ok", &response);
}

fn timeoutMs(milliseconds: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake } };
}

fn transportPair(options: zigot_modbus.TcpClient.Options) !struct {
    client: zigot_modbus.TcpClient,
    peer: std.Io.net.Stream,
} {
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var client = zigot_modbus.TcpClient.initWithOptions(io, options);
    errdefer client.disconnect();
    try client.connect("127.0.0.1", server.socket.address.getPort());
    const peer = try server.accept(io);
    return .{ .client = client, .peer = peer };
}

test "public API: input registers, coils and discrete inputs" {
    inline for (.{ @as(u8, 1), @as(u8, 2), @as(u8, 4) }) |function| {
        var pair = try transportPair(.{});
        defer pair.peer.close(std.testing.io);
        // Reuse the connected transport in the Modbus client.
        var client: zigot_modbus.SyncTcpModbusClient = .{ .transport = pair.client };
        defer client.disconnect();
        const quantity: u16 = if (function == 4) 2 else 10;
        const response = [_]u8{ 0, 0, 0, 0, 0, if (function == 4) 7 else 5, 1, function, if (function == 4) 4 else 2, 0x81, 0xfe, 0x56, 0x78 };
        var writer = pair.peer.writer(std.testing.io, &.{});
        try writer.interface.writeAll(response[0..if (function == 4) 13 else 11]);
        if (function == 4) {
            var registers: [3]u16 = .{ 0, 0, 99 };
            try std.testing.expectEqual(@as(usize, 2), try client.readInputRegister(0x1234, quantity, 1, &registers));
            try std.testing.expectEqualSlices(u16, &.{ 0x81fe, 0x5678, 99 }, &registers);
        } else {
            var bits: [11]bool = @splat(true);
            const count = if (function == 1) try client.readCoils(0x1234, quantity, 1, &bits) else try client.readDiscreteInputs(0x1234, quantity, 1, &bits);
            try std.testing.expectEqual(@as(usize, 10), count);
            try std.testing.expectEqualSlices(bool, &.{ true, false, false, false, false, false, false, true, false, true, true }, &bits);
        }
        var request: [12]u8 = undefined;
        try readPeerExact(pair.peer, &request);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 6, 1, function, 0x12, 0x34, 0, @intCast(quantity) }, &request);

        const exception = [_]u8{ 0, 1, 0, 0, 0, 3, 1, function | 0x80, 2 };
        try writer.interface.writeAll(&exception);
        var out: [10]if (function == 4) u16 else bool = undefined;
        const result = switch (function) {
            1 => try client.readCoilsDetailed(0, quantity, 1, &out),
            2 => try client.readDiscreteInputsDetailed(0, quantity, 1, &out),
            4 => try client.readInputRegisterDetailed(0, quantity, 1, &out),
            else => unreachable,
        };
        try std.testing.expectEqual(function, result.exception.function_code);
        try std.testing.expectEqual(zigot_modbus.modbus_codec.ExceptionCode.illegal_data_address, result.exception.exception_code);
    }
}

test "new TCP reads reject invalid requests and mismatched responses" {
    inline for (.{ @as(u8, 1), @as(u8, 2), @as(u8, 4) }) |function| {
        var pair = try transportPair(.{});
        defer pair.peer.close(std.testing.io);
        var client: zigot_modbus.SyncTcpModbusClient = .{ .transport = pair.client };
        defer client.disconnect();
        const read = switch (function) {
            1 => zigot_modbus.SyncTcpModbusClient.readCoils,
            2 => zigot_modbus.SyncTcpModbusClient.readDiscreteInputs,
            4 => zigot_modbus.SyncTcpModbusClient.readInputRegister,
            else => unreachable,
        };
        var out: [10]if (function == 4) u16 else bool = undefined;
        try std.testing.expectError(error.InvalidQuantity, read(&client, 0, 0, 1, &out));
        try std.testing.expectError(error.InvalidQuantity, read(&client, 0, if (function == 4) 126 else 2001, 1, &out));
        try std.testing.expectError(error.BufferTooSmall, read(&client, 0, 2, 1, out[0..1]));
        // A well-framed response with too little data for the requested quantity.
        const response = [_]u8{ 0, 0, 0, 0, 0, if (function == 4) 5 else 4, 1, function, if (function == 4) 2 else 1, 0, 0 };
        var writer = pair.peer.writer(std.testing.io, &.{});
        try writer.interface.writeAll(response[0..if (function == 4) 11 else 10]);
        try std.testing.expectError(error.InvalidByteCount, read(&client, 0, if (function == 4) 2 else 10, 1, &out));
        const unrelated_exception = [_]u8{ 0, 1, 0, 0, 0, 3, 1, 0x83, 2 };
        try writer.interface.writeAll(&unrelated_exception);
        try std.testing.expectError(error.InvalidFunctionCode, read(&client, 0, 1, 1, &out));
        const exception = [_]u8{ 0, 2, 0, 0, 0, 3, 1, function | 0x80, 2 };
        try writer.interface.writeAll(&exception);
        try std.testing.expectError(error.ModbusException, read(&client, 0, 1, 1, &out));
        client.disconnect();
        try std.testing.expectError(error.NotConnected, read(&client, 0, 1, 1, &out));
    }
}

test {
    _ = @import("writes.zig");
}

test {
    _ = @import("server.zig");
}

test {
    _ = @import("rtu.zig");
}
