const std = @import("std");
const modbus = @import("zigot_modbus");
const io = std.testing.io;

fn runServer(server: *modbus.TcpServer) !void {
    try server.serve();
}

test "TCP server supports all functions, limits, unit routing and exceptions" {
    var coils: [2000]bool = @splat(false);
    var holding: [125]u16 = @splat(0);
    const inputs = [_]u16{ 0x1234, 0xffff };
    const discrete = [_]bool{ true, false, true };
    const devices = [_]modbus.tcp_server.Device{
        .{ .unit_id = 1, .coils = &coils, .holding_registers = &holding, .input_registers = &inputs, .discrete_inputs = &discrete },
        .{ .unit_id = 7, .input_registers = &.{42} },
    };
    var server = try modbus.TcpServer.init(io, "127.0.0.1", 0, &devices, .{});
    defer server.deinit();
    var task = try io.concurrent(runServer, .{&server});
    defer _ = task.cancel(io) catch {};
    var client = modbus.SyncTcpModbusClient.init(io);
    defer client.disconnect();
    try client.connect("127.0.0.1", server.port());
    try std.testing.expectEqual(@as(usize, 1), try client.writeSingleCoil(0, true, 1));
    try std.testing.expectEqual(@as(usize, 1), try client.writeSingleRegister(0, 0xffff, 1));
    var bits: [2000]bool = undefined;
    _ = try client.readCoils(0, 2000, 1, &bits);
    try std.testing.expect(bits[0] and !bits[1999]);
    var registers: [125]u16 = undefined;
    _ = try client.readHoldingRegister(0, 125, 1, &registers);
    try std.testing.expectEqual(@as(u16, 0xffff), registers[0]);
    const values: [123]u16 = @splat(0x8001);
    _ = try client.writeMultipleRegisters(1, &values, 1);
    _ = try client.readHoldingRegister(1, 123, 1, &registers);
    try std.testing.expectEqualSlices(u16, &values, registers[0..123]);
    const flags: [1968]bool = @splat(true);
    _ = try client.writeMultipleCoils(1, &flags, 1);
    _ = try client.readCoils(1, 1968, 1, &bits);
    try std.testing.expectEqualSlices(bool, &flags, bits[0..1968]);
    _ = try client.readDiscreteInputs(0, 3, 1, &bits);
    try std.testing.expectEqualSlices(bool, &discrete, bits[0..3]);
    _ = try client.readInputRegister(0, 2, 1, &registers);
    try std.testing.expectEqualSlices(u16, &inputs, registers[0..2]);
    _ = try client.readInputRegister(0, 1, 7, &registers);
    try std.testing.expectEqual(@as(u16, 42), registers[0]);
    const bad_address = try client.readInputRegisterDetailed(2, 1, 1, &registers);
    try std.testing.expectEqual(modbus.modbus_codec.ExceptionCode.illegal_data_address, bad_address.exception.exception_code);
    const unknown = try client.readInputRegisterDetailed(0, 1, 99, &registers);
    try std.testing.expectEqual(modbus.modbus_codec.ExceptionCode.gateway_target_device_failed_to_respond, unknown.exception.exception_code);
}

test "concurrent clients observe atomic register writes while another peer is incomplete" {
    var holding: [123]u16 = @splat(0);
    const devices = [_]modbus.tcp_server.Device{.{ .unit_id = 1, .holding_registers = &holding }};
    var server = try modbus.TcpServer.init(io, "127.0.0.1", 0, &devices, .{ .max_clients = 10 });
    defer server.deinit();
    var task = try io.concurrent(runServer, .{&server});
    defer _ = task.cancel(io) catch {};
    var stalled = modbus.TcpClient.init(io);
    defer stalled.disconnect();
    try stalled.connect("127.0.0.1", server.port());
    try stalled.send(&.{ 0, 1, 0 }); // Partial MBAP header must not block other clients.
    const Worker = struct {
        fn run(port: u16, value: u16, gate: *std.Io.Event) anyerror!void {
            var client = modbus.SyncTcpModbusClient.init(io);
            defer client.disconnect();
            try client.connect("127.0.0.1", port);
            try gate.wait(io);
            const values: [123]u16 = @splat(value);
            for (0..25) |_| {
                _ = try client.writeMultipleRegisters(0, &values, 1);
                var actual: [123]u16 = undefined;
                _ = try client.readHoldingRegister(0, 123, 1, &actual);
                // Another writer may win, but no read may observe a torn write.
                for (actual) |register| try std.testing.expectEqual(actual[0], register);
            }
        }
    };
    var gate: std.Io.Event = .unset;
    var workers: [8]std.Io.Future(anyerror!void) = undefined;
    var started: usize = 0;
    defer for (workers[0..started]) |*worker| {
        _ = worker.cancel(io) catch {};
    };
    for (&workers, 0..) |*worker, index| {
        worker.* = try io.concurrent(Worker.run, .{ server.port(), @as(u16, @intCast(index + 1)), &gate });
        started += 1;
    }
    gate.set(io);
    for (&workers) |*worker| try worker.await(io);
    // Cancellation above must also interrupt the stalled client's receive.
}

test "TCP server handles fragmented and pipelined frames and isolates malformed peers" {
    var holding = [_]u16{ 12, 13 };
    const devices = [_]modbus.tcp_server.Device{.{ .unit_id = 1, .holding_registers = &holding }};
    var server = try modbus.TcpServer.init(io, "127.0.0.1", 0, &devices, .{});
    defer server.deinit();
    var task = try io.concurrent(runServer, .{&server});
    defer _ = task.cancel(io) catch {};
    var raw = modbus.TcpClient.init(io);
    defer raw.disconnect();
    try raw.connect("127.0.0.1", server.port());
    var first: [12]u8 = undefined;
    _ = try modbus.modbus_codec.encode_read_holding_registers_request(0x1234, 1, 0, 2, &first);
    try raw.send(first[0..3]);
    // Finish the fragmented frame and queue the next request in one send.
    var tail: [21]u8 = undefined;
    @memcpy(tail[0..9], first[3..]);
    @memcpy(tail[9..], &first);
    tail[10] = 0x35;
    try raw.send(&tail);
    var responses: [26]u8 = undefined;
    try raw.receiveExact(&responses);
    var out: [2]u16 = undefined;
    _ = try modbus.modbus_codec.decode_read_holding_registers_response(responses[0..13], 0x1234, 1, &out);
    _ = try modbus.modbus_codec.decode_read_holding_registers_response(responses[13..], 0x1235, 1, &out);
    try std.testing.expectEqualSlices(u16, &holding, &out);
    first[3] = 1; // Invalid protocol closes only this peer.
    try raw.send(&first);
    var byte: [1]u8 = undefined;
    // Some operating systems report reset rather than orderly EOF.
    const count = raw.receive(&byte) catch |err| switch (err) {
        error.ConnectionResetByPeer => 0,
        else => return err,
    };
    try std.testing.expectEqual(@as(usize, 0), count);
    var healthy = modbus.SyncTcpModbusClient.init(io);
    defer healthy.disconnect();
    try healthy.connect("127.0.0.1", server.port());
    _ = try healthy.readHoldingRegister(0, 2, 1, &out);
}

test "client limit releases slots and cancellation closes idle accepted sockets" {
    var registers = [_]u16{0};
    const devices = [_]modbus.tcp_server.Device{.{ .unit_id = 1, .holding_registers = &registers }};
    var server = try modbus.TcpServer.init(io, "127.0.0.1", 0, &devices, .{ .max_clients = 1 });
    defer server.deinit();
    var task = try io.concurrent(runServer, .{&server});
    defer _ = task.cancel(io) catch {};
    var first = modbus.SyncTcpModbusClient.init(io);
    defer first.disconnect();
    try first.connect("127.0.0.1", server.port());
    var out: [1]u16 = undefined;
    _ = try first.readHoldingRegister(0, 1, 1, &out); // The only worker is occupied.
    var second = modbus.TcpClient.init(io);
    defer second.disconnect();
    try second.connect("127.0.0.1", server.port());
    var request: [12]u8 = undefined;
    _ = try modbus.modbus_codec.encode_write_single_register_request(7, 1, 0, 42, &request);
    try second.send(&request);
    _ = try first.readHoldingRegister(0, 1, 1, &out);
    try std.testing.expectEqual(@as(u16, 0), out[0]);
    first.disconnect();
    var response: [12]u8 = undefined;
    try second.receiveExact(&response);
    _ = try modbus.modbus_codec.decode_write_single_register_response(&response, 7, 1, 0, 42);
    // Cancel while an accepted peer is still connected and waiting for a request.
    _ = task.cancel(io) catch {};
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try second.receive(&byte));
}

test "partial request timeout closes the peer without stopping the server" {
    const devices = [_]modbus.tcp_server.Device{.{ .unit_id = 1, .input_registers = &.{42} }};
    var server = try modbus.TcpServer.init(io, "127.0.0.1", 0, &devices, .{
        .read_timeout = .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } },
    });
    defer server.deinit();
    var task = try io.concurrent(runServer, .{&server});
    defer _ = task.cancel(io) catch {};
    var slow = modbus.TcpClient.init(io);
    defer slow.disconnect();
    try slow.connect("127.0.0.1", server.port());
    try slow.send(&.{ 0, 1, 0 });
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try slow.receive(&byte));
    var client = modbus.SyncTcpModbusClient.init(io);
    defer client.disconnect();
    try client.connect("127.0.0.1", server.port());
    var out: [1]u16 = undefined;
    _ = try client.readInputRegister(0, 1, 1, &out);
    try std.testing.expectEqual(@as(u16, 42), out[0]);
}
