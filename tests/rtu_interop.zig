const std = @import("std");
const modbus = @import("zigot_modbus");
const vectors = @import("interop_vectors");
const options = @import("interop_options");

test "PyModbus RTU reference-client vectors match Zig reads and writes" {
    var transport = modbus.TcpClient.init(std.testing.io);
    defer transport.disconnect();
    try transport.connect("127.0.0.1", options.port);
    var client = modbus.SyncRtuModbusClient.init(.{ .context = &transport, .exchange = exchange });
    for (vectors.cases, 0..) |case, index| {
        errdefer std.debug.print("interop case {}: fc={} unit={} address={} quantity={}\n", .{ index, case.function, case.unit, case.address, case.quantity });
        // One extra element acts as a sentinel for writes beyond the requested quantity.
        var registers: [126]u16 = @splat(0xdead);
        var bits: [2001]bool = @splat(true);
        const result = try switch (case.function) {
            1 => client.readCoilsDetailed(case.address, case.quantity, case.unit, &bits),
            2 => client.readDiscreteInputsDetailed(case.address, case.quantity, case.unit, &bits),
            3 => client.readHoldingRegisterDetailed(case.address, case.quantity, case.unit, &registers),
            4 => client.readInputRegisterDetailed(case.address, case.quantity, case.unit, &registers),
            else => unreachable,
        };
        if (case.exception != 0) {
            try std.testing.expect(result == .exception);
            try std.testing.expectEqual(case.exception, @backingInt(result.exception.exception_code));
            try std.testing.expectEqual(case.function, result.exception.function_code);
            try std.testing.expectEqual(case.unit, result.exception.unit_id);
            continue;
        }
        try std.testing.expect(result == .count);
        try std.testing.expectEqual(@as(usize, case.quantity), result.count);
        if (case.function <= 2) {
            for (case.values, bits[0..case.quantity]) |expected, actual| {
                try std.testing.expectEqual(expected != 0, actual);
            }
            try std.testing.expect(bits[case.quantity]);
        } else {
            try std.testing.expectEqualSlices(u16, case.values, registers[0..case.quantity]);
            try std.testing.expectEqual(@as(u16, 0xdead), registers[case.quantity]);
        }
    }
    // Writes run after read vectors so their state changes cannot invalidate the oracle.
    for (vectors.writes) |case| {
        errdefer std.debug.print("write fc={} unit={} address={} quantity={}\n", .{ case.function, case.unit, case.address, case.quantity });
        var bits: [1968]bool = undefined;
        for (case.values, 0..) |value, index| {
            if (case.function == 5 or case.function == 15) bits[index] = value != 0;
        }
        const result = try switch (case.function) {
            5 => client.writeSingleCoilDetailed(case.address, case.values[0] != 0, case.unit),
            6 => client.writeSingleRegisterDetailed(case.address, case.values[0], case.unit),
            15 => client.writeMultipleCoilsDetailed(case.address, bits[0..case.quantity], case.unit),
            16 => client.writeMultipleRegistersDetailed(case.address, case.values, case.unit),
            else => unreachable,
        };
        if (case.exception != 0) {
            try std.testing.expect(result == .exception);
            try std.testing.expectEqual(case.exception, @backingInt(result.exception.exception_code));
            try std.testing.expectEqual(case.function, result.exception.function_code);
            continue;
        }
        try std.testing.expect(result == .count);
        try std.testing.expectEqual(@as(usize, case.quantity), result.count);
        if (case.function == 5 or case.function == 15) {
            var actual: [1968]bool = undefined;
            try std.testing.expectEqual(@as(usize, case.quantity), try client.readCoils(case.address, case.quantity, case.unit, &actual));
            try std.testing.expectEqualSlices(bool, bits[0..case.quantity], actual[0..case.quantity]);
        } else {
            var actual: [123]u16 = undefined;
            try std.testing.expectEqual(@as(usize, case.quantity), try client.readHoldingRegister(case.address, case.quantity, case.unit, &actual));
            try std.testing.expectEqualSlices(u16, case.values, actual[0..case.quantity]);
        }
    }
}

// Test-only RTU-over-TCP adapter. Production serial adapters must additionally
// enforce serial timing and recover/drain the bus on errors.
fn exchange(context: *anyopaque, request: []const u8, response: []u8) !usize {
    const stream: *modbus.TcpClient = @ptrCast(@alignCast(context));
    try stream.send(request);
    try stream.receiveExact(response[0..3]);
    const n: usize = if (response[1] & 0x80 != 0) 5 else if (response[1] <= 4) @as(usize, response[2]) + 5 else 8;
    if (n > response.len) return error.ResponseTooLarge;
    // Deliberately receive one byte at a time to exercise stream fragmentation.
    for (3..n) |i| try stream.receiveExact(response[i .. i + 1]);
    return n;
}
