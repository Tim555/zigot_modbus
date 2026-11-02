const std = @import("std");

pub const default_port: u16 = 502;
pub const mbap_header_length: usize = 7;
pub const max_adu_length: usize = 260;

pub const MbapHeader = struct {
    transaction_id: u16,
    protocol_id: u16,
    length: u16,
    unit_id: u8,
};

pub const ExceptionCode = enum(u8) {
    illegal_function = 0x01,
    illegal_data_address = 0x02,
    illegal_data_value = 0x03,
    slave_device_failure = 0x04,
    acknowledge = 0x05,
    slave_device_busy = 0x06,
    negative_acknowledge = 0x07,
    memory_parity_error = 0x08,
    gateway_path_unavailable = 0x0a,
    gateway_target_device_failed_to_respond = 0x0b,
    _,
};

pub const ModbusErrorKind = enum {
    no_response,
    malformed_response,
    invalid_function_code,
    invalid_protocol_id,
    invalid_length,
    transaction_id_mismatch,
    unit_id_mismatch,
    modbus_exception,
    illegal_function,
    illegal_data_address,
    illegal_data_value,
    slave_device_failure,
    acknowledge,
    slave_device_busy,
    negative_acknowledge,
    memory_parity_error,
    gateway_path_unavailable,
    gateway_target_device_failed_to_respond,
};

pub const ModbusException = struct {
    function_code: u8,
    exception_code: ExceptionCode,
    kind: ModbusErrorKind,
    transaction_id: u16,
    protocol_id: u16,
    unit_id: u8,
    header: MbapHeader,
    pdu: [max_adu_length]u8 = undefined,
    pdu_len: usize = 0,
    raw_frame: [max_adu_length]u8 = undefined,
    raw_frame_len: usize = 0,
};

pub const ModbusFrameError = struct {
    kind: ModbusErrorKind,
    transaction_id: u16,
    protocol_id: u16,
    unit_id: u8,
    header: MbapHeader,
    pdu: [max_adu_length]u8 = undefined,
    pdu_len: usize = 0,
    function_code: ?u8 = null,
    exception_code: ?ExceptionCode = null,
    message: []const u8,
};

pub fn encode_mbap_header(transaction_id: u16, protocol_id: u16, length: u16, unit_id: u8, out: []u8) !void {
    if (out.len < mbap_header_length) return error.BufferTooSmall;

    out[0] = @as(u8, @intCast((transaction_id >> 8) & 0xff));
    out[1] = @as(u8, @intCast(transaction_id & 0xff));
    out[2] = @as(u8, @intCast((protocol_id >> 8) & 0xff));
    out[3] = @as(u8, @intCast(protocol_id & 0xff));
    out[4] = @as(u8, @intCast((length >> 8) & 0xff));
    out[5] = @as(u8, @intCast(length & 0xff));
    out[6] = unit_id;
}

pub fn decode_mbap_header(frame: []const u8) !MbapHeader {
    if (frame.len < mbap_header_length) return error.BufferTooSmall;

    return MbapHeader{
        .transaction_id = @as(u16, @intCast(((@as(u16, frame[0]) << 8) | @as(u16, frame[1])))),
        .protocol_id = @as(u16, @intCast(((@as(u16, frame[2]) << 8) | @as(u16, frame[3])))),
        .length = @as(u16, @intCast(((@as(u16, frame[4]) << 8) | @as(u16, frame[5])))),
        .unit_id = frame[6],
    };
}

pub fn encode_read_holding_registers_request(transaction_id: u16, unit_id: u8, address: u16, quantity: u16, out: []u8) !usize {
    return encode_read_request(3, 125, transaction_id, unit_id, address, quantity, out);
}

pub fn encode_read_input_registers_request(transaction_id: u16, unit_id: u8, address: u16, quantity: u16, out: []u8) !usize {
    return encode_read_request(4, 125, transaction_id, unit_id, address, quantity, out);
}

pub fn encode_read_coils_request(transaction_id: u16, unit_id: u8, address: u16, quantity: u16, out: []u8) !usize {
    return encode_read_request(1, 2000, transaction_id, unit_id, address, quantity, out);
}

pub fn encode_read_discrete_inputs_request(transaction_id: u16, unit_id: u8, address: u16, quantity: u16, out: []u8) !usize {
    return encode_read_request(2, 2000, transaction_id, unit_id, address, quantity, out);
}

fn encode_read_request(function_code: u8, max_quantity: u16, transaction_id: u16, unit_id: u8, address: u16, quantity: u16, out: []u8) !usize {
    if (quantity == 0 or quantity > max_quantity) return error.InvalidQuantity;
    if (out.len < mbap_header_length + 5) return error.BufferTooSmall;

    try encode_mbap_header(transaction_id, 0, 6, unit_id, out[0..mbap_header_length]);
    out[7] = function_code;
    out[8] = @as(u8, @intCast((address >> 8) & 0xff));
    out[9] = @as(u8, @intCast(address & 0xff));
    out[10] = @as(u8, @intCast((quantity >> 8) & 0xff));
    out[11] = @as(u8, @intCast(quantity & 0xff));
    return mbap_header_length + 5;
}

pub fn decode_exception_response(frame: []const u8, expected_transaction_id: u16, expected_unit_id: u8) !ModbusException {
    const header = try decode_mbap_header(frame);

    if (header.transaction_id != expected_transaction_id) return error.TransactionIdMismatch;
    if (header.protocol_id != 0) return error.InvalidProtocolId;
    if (header.unit_id != expected_unit_id) return error.UnitIdMismatch;
    if (header.length != 3) return error.InvalidLength;
    if (frame.len != 9) return error.InvalidLength;

    const function_code = frame[7];
    if ((function_code & 0x80) == 0) return error.InvalidFunctionCode;

    const exception_code = @as(ExceptionCode, @fromBackingInt(@intCast(frame[8])));
    var exc = ModbusException{
        .function_code = function_code & 0x7f,
        .exception_code = exception_code,
        .kind = switch (exception_code) {
            .illegal_function => .illegal_function,
            .illegal_data_address => .illegal_data_address,
            .illegal_data_value => .illegal_data_value,
            .slave_device_failure => .slave_device_failure,
            .acknowledge => .acknowledge,
            .slave_device_busy => .slave_device_busy,
            .negative_acknowledge => .negative_acknowledge,
            .memory_parity_error => .memory_parity_error,
            .gateway_path_unavailable => .gateway_path_unavailable,
            .gateway_target_device_failed_to_respond => .gateway_target_device_failed_to_respond,
            else => .modbus_exception,
        },
        .transaction_id = header.transaction_id,
        .protocol_id = header.protocol_id,
        .unit_id = header.unit_id,
        .header = header,
    };
    exc.pdu_len = frame.len - 7;
    std.mem.copyForwards(u8, exc.pdu[0..exc.pdu_len], frame[7..]);
    exc.raw_frame_len = frame.len;
    std.mem.copyForwards(u8, exc.raw_frame[0..exc.raw_frame_len], frame);
    return exc;
}

pub fn decode_modbus_error(frame: []const u8, expected_transaction_id: u16, expected_unit_id: u8) ModbusFrameError {
    const empty_header = MbapHeader{
        .transaction_id = expected_transaction_id,
        .protocol_id = 0,
        .length = 0,
        .unit_id = expected_unit_id,
    };

    const header = decode_mbap_header(frame) catch {
        var error_details = ModbusFrameError{
            .kind = .no_response,
            .transaction_id = expected_transaction_id,
            .protocol_id = empty_header.protocol_id,
            .unit_id = expected_unit_id,
            .header = empty_header,
            .message = "No complete MBAP header or truncated response received",
        };
        error_details.pdu_len = frame.len;
        std.mem.copyForwards(u8, error_details.pdu[0..error_details.pdu_len], frame);
        return error_details;
    };

    var pdu: [max_adu_length]u8 = undefined;
    var pdu_len: usize = 0;
    if (frame.len > mbap_header_length) {
        pdu_len = frame.len - mbap_header_length;
        std.mem.copyForwards(u8, pdu[0..pdu_len], frame[mbap_header_length..]);
    }
    if (header.transaction_id != expected_transaction_id) {
        return ModbusFrameError{
            .kind = .transaction_id_mismatch,
            .transaction_id = header.transaction_id,
            .protocol_id = header.protocol_id,
            .unit_id = header.unit_id,
            .header = header,
            .pdu = pdu,
            .pdu_len = pdu_len,
            .message = "Transaction ID mismatch",
        };
    }
    if (header.protocol_id != 0) {
        return ModbusFrameError{
            .kind = .invalid_protocol_id,
            .transaction_id = header.transaction_id,
            .protocol_id = header.protocol_id,
            .unit_id = header.unit_id,
            .header = header,
            .pdu = pdu,
            .pdu_len = pdu_len,
            .message = "Unexpected protocol ID",
        };
    }
    if (header.unit_id != expected_unit_id) {
        return ModbusFrameError{
            .kind = .unit_id_mismatch,
            .transaction_id = header.transaction_id,
            .protocol_id = header.protocol_id,
            .unit_id = header.unit_id,
            .header = header,
            .pdu = pdu,
            .pdu_len = pdu_len,
            .message = "Unit ID mismatch",
        };
    }
    if (frame.len < 8) {
        return ModbusFrameError{
            .kind = .malformed_response,
            .transaction_id = header.transaction_id,
            .protocol_id = header.protocol_id,
            .unit_id = header.unit_id,
            .header = header,
            .pdu = pdu,
            .pdu_len = pdu_len,
            .message = "Frame is truncated before the function code",
        };
    }

    const function_code = frame[7];
    if ((function_code & 0x80) != 0) {
        const exc = decode_exception_response(frame, expected_transaction_id, expected_unit_id) catch |err| {
            var error_details = ModbusFrameError{
                .kind = .malformed_response,
                .transaction_id = header.transaction_id,
                .protocol_id = header.protocol_id,
                .unit_id = header.unit_id,
                .header = header,
                .message = @errorName(err),
            };
            error_details.pdu_len = pdu_len;
            std.mem.copyForwards(u8, error_details.pdu[0..error_details.pdu_len], pdu[0..pdu_len]);
            return error_details;
        };
        var error_details = ModbusFrameError{
            .kind = exc.kind,
            .transaction_id = exc.transaction_id,
            .protocol_id = exc.protocol_id,
            .unit_id = exc.unit_id,
            .header = exc.header,
            .function_code = exc.function_code,
            .exception_code = exc.exception_code,
            .message = "Modbus exception response",
        };
        error_details.pdu_len = exc.pdu_len;
        std.mem.copyForwards(u8, error_details.pdu[0..error_details.pdu_len], exc.pdu[0..exc.pdu_len]);
        return error_details;
    }

    return ModbusFrameError{
        .kind = if (function_code != 0x03) .invalid_function_code else .modbus_exception,
        .transaction_id = header.transaction_id,
        .protocol_id = header.protocol_id,
        .unit_id = header.unit_id,
        .header = header,
        .pdu = pdu,
        .pdu_len = pdu_len,
        .function_code = function_code,
        .message = if (function_code != 0x03) "Unexpected function code in response" else "Response is a valid Modbus function without exception",
    };
}

pub fn decode_read_holding_registers_response(frame: []const u8, expected_transaction_id: u16, expected_unit_id: u8, out: []u16) !usize {
    return decode_read_registers_response(3, frame, expected_transaction_id, expected_unit_id, out);
}

pub fn decode_read_input_registers_response(frame: []const u8, expected_transaction_id: u16, expected_unit_id: u8, out: []u16) !usize {
    return decode_read_registers_response(4, frame, expected_transaction_id, expected_unit_id, out);
}

/// Decode exactly quantity bits, least significant bit first; ignore final-byte padding.
pub fn decode_read_coils_response(frame: []const u8, expected_transaction_id: u16, expected_unit_id: u8, quantity: u16, out: []bool) !usize {
    return decode_read_bits_response(1, frame, expected_transaction_id, expected_unit_id, quantity, out);
}

/// Decode exactly quantity bits, least significant bit first; ignore final-byte padding.
pub fn decode_read_discrete_inputs_response(frame: []const u8, expected_transaction_id: u16, expected_unit_id: u8, quantity: u16, out: []bool) !usize {
    return decode_read_bits_response(2, frame, expected_transaction_id, expected_unit_id, quantity, out);
}

fn decode_read_registers_response(expected_function: u8, frame: []const u8, expected_transaction_id: u16, expected_unit_id: u8, out: []u16) !usize {
    const header = try decode_mbap_header(frame);

    if (header.transaction_id != expected_transaction_id) return error.TransactionIdMismatch;
    if (header.protocol_id != 0) return error.InvalidProtocolId;
    if (header.unit_id != expected_unit_id) return error.UnitIdMismatch;
    if (header.length < 3) return error.InvalidLength;
    if (frame.len != 6 + @as(usize, header.length)) return error.InvalidLength;
    if (frame.len < 9) return error.InvalidLength;

    const function_code = frame[7];
    if ((function_code & 0x80) != 0) {
        const exc = try decode_exception_response(frame, expected_transaction_id, expected_unit_id);
        if (exc.function_code != expected_function) return error.InvalidFunctionCode;
        return error.ModbusException;
    }
    if (function_code != expected_function) return error.InvalidFunctionCode;

    const byte_count: usize = frame[8];
    if (byte_count == 0 or (byte_count % 2) != 0) return error.InvalidByteCount;
    if (frame.len != 9 + byte_count) return error.InvalidLength;
    if (out.len < (byte_count / 2)) return error.BufferTooSmall;

    for (0..(byte_count / 2)) |index| {
        const offset = 9 + index * 2;
        out[index] = @as(u16, @intCast(((@as(u16, frame[offset]) << 8) | @as(u16, frame[offset + 1]))));
    }

    return byte_count / 2;
}

fn decode_read_bits_response(expected_function: u8, frame: []const u8, expected_transaction_id: u16, expected_unit_id: u8, quantity: u16, out: []bool) !usize {
    if (quantity == 0 or quantity > 2000) return error.InvalidQuantity;
    const header = try decode_mbap_header(frame);
    if (header.transaction_id != expected_transaction_id) return error.TransactionIdMismatch;
    if (header.protocol_id != 0) return error.InvalidProtocolId;
    if (header.unit_id != expected_unit_id) return error.UnitIdMismatch;
    if (header.length < 3 or frame.len != 6 + @as(usize, header.length)) return error.InvalidLength;
    if (frame[7] == (expected_function | 0x80)) {
        _ = try decode_exception_response(frame, expected_transaction_id, expected_unit_id);
        return error.ModbusException;
    }
    if (frame[7] != expected_function) return error.InvalidFunctionCode;
    const byte_count = (@as(usize, quantity) + 7) / 8;
    if (frame[8] != byte_count) return error.InvalidByteCount;
    if (frame.len != 9 + byte_count) return error.InvalidLength;
    if (out.len < quantity) return error.BufferTooSmall;
    for (0..quantity) |index| {
        out[index] = (frame[9 + index / 8] & (@as(u8, 1) << @as(u3, @intCast(index % 8)))) != 0;
    }
    return quantity;
}

test "encode_mbap_header" {
    var header: [mbap_header_length]u8 = undefined;
    try encode_mbap_header(0x1234, 0x5678, 0x9ABC, 0xDE, &header);

    try std.testing.expectEqual(@as(u8, 0x12), header[0]);
    try std.testing.expectEqual(@as(u8, 0x34), header[1]);
    try std.testing.expectEqual(@as(u8, 0x56), header[2]);
    try std.testing.expectEqual(@as(u8, 0x78), header[3]);
    try std.testing.expectEqual(@as(u8, 0x9A), header[4]);
    try std.testing.expectEqual(@as(u8, 0xBC), header[5]);
    try std.testing.expectEqual(@as(u8, 0xDE), header[6]);
}

test "decode_mbap_header" {
    const frame = [_]u8{ 0x12, 0x34, 0x00, 0x00, 0x00, 0x07, 0x01 };
    const header = try decode_mbap_header(&frame);

    try std.testing.expectEqual(@as(u16, 0x1234), header.transaction_id);
    try std.testing.expectEqual(@as(u16, 0), header.protocol_id);
    try std.testing.expectEqual(@as(u16, 7), header.length);
    try std.testing.expectEqual(@as(u8, 0x01), header.unit_id);
}

test "encode_read_holding_registers_request" {
    var request: [mbap_header_length + 5]u8 = undefined;
    const len = try encode_read_holding_registers_request(0x1234, 0x01, 0x1234, 0x0002, &request);

    try std.testing.expectEqual(@as(usize, 12), len);
    try std.testing.expectEqual(@as(u8, 0x12), request[0]);
    try std.testing.expectEqual(@as(u8, 0x34), request[1]);
    try std.testing.expectEqual(@as(u8, 0x00), request[2]);
    try std.testing.expectEqual(@as(u8, 0x00), request[3]);
    try std.testing.expectEqual(@as(u8, 0x00), request[4]);
    try std.testing.expectEqual(@as(u8, 0x06), request[5]);
    try std.testing.expectEqual(@as(u8, 0x01), request[6]);
    try std.testing.expectEqual(@as(u8, 0x03), request[7]);
    try std.testing.expectEqual(@as(u8, 0x12), request[8]);
    try std.testing.expectEqual(@as(u8, 0x34), request[9]);
    try std.testing.expectEqual(@as(u8, 0x00), request[10]);
    try std.testing.expectEqual(@as(u8, 0x02), request[11]);
}

test "decode_read_holding_registers_response" {
    const response = [_]u8{ 0x12, 0x34, 0x00, 0x00, 0x00, 0x07, 0x01, 0x03, 0x04, 0x12, 0x34, 0x56, 0x78 };
    var registers: [2]u16 = undefined;
    const count = try decode_read_holding_registers_response(&response, 0x1234, 0x01, &registers);

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u16, 0x1234), registers[0]);
    try std.testing.expectEqual(@as(u16, 0x5678), registers[1]);
}

test "decode_exception_response" {
    const response = [_]u8{ 0x12, 0x34, 0x00, 0x00, 0x00, 0x03, 0x01, 0x83, 0x02 };
    const exc = try decode_exception_response(&response, 0x1234, 0x01);

    try std.testing.expectEqual(@as(u8, 0x03), exc.function_code);
    try std.testing.expectEqual(@as(ExceptionCode, .illegal_data_address), exc.exception_code);
    try std.testing.expectEqual(@as(u16, 0x1234), exc.transaction_id);
    try std.testing.expectEqual(@as(u8, 0x01), exc.unit_id);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x83, 0x02 }, exc.pdu[0..exc.pdu_len]);
}

test "decode_modbus_error reports full context" {
    const response = [_]u8{ 0x12, 0x34, 0x00, 0x00, 0x00, 0x03, 0x01, 0x83, 0x02 };
    const error_details = decode_modbus_error(&response, 0x1234, 0x01);

    try std.testing.expectEqual(@as(ModbusErrorKind, .illegal_data_address), error_details.kind);
    try std.testing.expectEqual(@as(u16, 0x1234), error_details.transaction_id);
    try std.testing.expectEqual(@as(u16, 0), error_details.protocol_id);
    try std.testing.expectEqual(@as(u8, 0x01), error_details.unit_id);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x83, 0x02 }, error_details.pdu[0..error_details.pdu_len]);
}

test "decode_exception_response covers every exception code" {
    const cases = [_]struct { code: u8, expected: ExceptionCode, expected_kind: ModbusErrorKind }{
        .{ .code = 0x01, .expected = .illegal_function, .expected_kind = .illegal_function },
        .{ .code = 0x02, .expected = .illegal_data_address, .expected_kind = .illegal_data_address },
        .{ .code = 0x03, .expected = .illegal_data_value, .expected_kind = .illegal_data_value },
        .{ .code = 0x04, .expected = .slave_device_failure, .expected_kind = .slave_device_failure },
        .{ .code = 0x05, .expected = .acknowledge, .expected_kind = .acknowledge },
        .{ .code = 0x06, .expected = .slave_device_busy, .expected_kind = .slave_device_busy },
        .{ .code = 0x07, .expected = .negative_acknowledge, .expected_kind = .negative_acknowledge },
        .{ .code = 0x08, .expected = .memory_parity_error, .expected_kind = .memory_parity_error },
        .{ .code = 0x0a, .expected = .gateway_path_unavailable, .expected_kind = .gateway_path_unavailable },
        .{ .code = 0x0b, .expected = .gateway_target_device_failed_to_respond, .expected_kind = .gateway_target_device_failed_to_respond },
    };

    for (cases) |case| {
        const response = [_]u8{ 0x12, 0x34, 0x00, 0x00, 0x00, 0x03, 0x01, 0x83, case.code };

        const exc = try decode_exception_response(&response, 0x1234, 0x01);
        try std.testing.expectEqual(case.expected, exc.exception_code);
        try std.testing.expectEqual(case.expected_kind, exc.kind);
        try std.testing.expectEqual(@as(u8, 0x03), exc.function_code);
        try std.testing.expectEqual(@as(u16, 0x1234), exc.transaction_id);
        try std.testing.expectEqual(@as(u8, 0x01), exc.unit_id);

        const details = decode_modbus_error(&response, 0x1234, 0x01);
        try std.testing.expectEqual(case.expected_kind, details.kind);
        try std.testing.expectEqual(@as(u8, case.code), @backingInt(details.exception_code.?));
    }
}

test "decode_read_holding_registers_response preserves generic modbus exception" {
    const response = [_]u8{ 0x12, 0x34, 0x00, 0x00, 0x00, 0x03, 0x01, 0x83, 0x02 };
    var registers: [1]u16 = undefined;

    try std.testing.expectError(error.ModbusException, decode_read_holding_registers_response(&response, 0x1234, 0x01, &registers));
}

test "decode_read_holding_registers_response rejects unrelated exceptions" {
    const response = [_]u8{ 0x12, 0x34, 0x00, 0x00, 0x00, 0x03, 0x01, 0x84, 0x02 };
    var registers: [1]u16 = undefined;

    try std.testing.expectError(error.InvalidFunctionCode, decode_read_holding_registers_response(&response, 0x1234, 0x01, &registers));
}

test "new read request quantity and buffer limits" {
    inline for (.{ encode_read_input_registers_request, encode_read_coils_request, encode_read_discrete_inputs_request }, .{ @as(u16, 125), @as(u16, 2000), @as(u16, 2000) }) |encode, limit| {
        var request: [12]u8 = undefined;
        try std.testing.expectError(error.InvalidQuantity, encode(0, 1, 0, 0, &request));
        try std.testing.expectError(error.InvalidQuantity, encode(0, 1, 0, limit + 1, &request));
        try std.testing.expectError(error.BufferTooSmall, encode(0, 1, 0, limit, request[0..11]));
        try std.testing.expectEqual(@as(usize, 12), try encode(0, 1, 0, limit, &request));
    }
}

test "bit responses validate framing, quantity, and function before writing" {
    inline for (.{ decode_read_coils_response, decode_read_discrete_inputs_response }, .{ @as(u8, 1), @as(u8, 2) }) |decode, function| {
        var frame = [_]u8{ 0, 0, 0, 0, 0, 5, 1, function, 2, 0x81, 0xff };
        var bits: [10]bool = @splat(false);
        try std.testing.expectError(error.InvalidQuantity, decode(&frame, 0, 1, 0, &bits));
        try std.testing.expectError(error.InvalidQuantity, decode(&frame, 0, 1, 2001, &bits));
        try std.testing.expectError(error.BufferTooSmall, decode(&frame, 0, 1, 10, bits[0..9]));
        try std.testing.expectError(error.TransactionIdMismatch, decode(&frame, 1, 1, 10, &bits));
        try std.testing.expectError(error.UnitIdMismatch, decode(&frame, 0, 2, 10, &bits));
        try std.testing.expectError(error.InvalidLength, decode(frame[0..10], 0, 1, 10, &bits));
        frame[8] = 1;
        try std.testing.expectError(error.InvalidByteCount, decode(&frame, 0, 1, 10, &bits));
        frame[8] = 2;
        frame[7] = 3;
        try std.testing.expectError(error.InvalidFunctionCode, decode(&frame, 0, 1, 10, &bits));
        frame[7] = function;
        try std.testing.expectEqual(@as(usize, 10), try decode(&frame, 0, 1, 10, &bits));
        try std.testing.expect(bits[0] and bits[7] and bits[8] and bits[9]);
    }
}

test "register decoder accepts maximum-sized responses without byte-count overflow" {
    inline for (.{ decode_read_holding_registers_response, decode_read_input_registers_response }, .{ @as(u8, 3), @as(u8, 4) }) |decode, function| {
        var frame: [259]u8 = @splat(0xff);
        try encode_mbap_header(0, 0, 253, 1, &frame);
        frame[7] = function;
        frame[8] = 250;
        var out: [125]u16 = undefined;
        try std.testing.expectEqual(@as(usize, 125), try decode(&frame, 0, 1, &out));
        for (out) |register| try std.testing.expectEqual(@as(u16, 0xffff), register);
    }
}

test "read decoders reject overflowing MBAP lengths" {
    var registers: [1]u16 = undefined;
    var bits: [1]bool = undefined;
    const frame = [_]u8{ 0, 0, 0, 0, 0xff, 0xff, 1, 4, 2, 0, 1 };
    try std.testing.expectError(error.InvalidLength, decode_read_input_registers_response(&frame, 0, 1, &registers));
    try std.testing.expectError(error.InvalidLength, decode_read_holding_registers_response(&frame, 0, 1, &registers));
    try std.testing.expectError(error.InvalidLength, decode_read_coils_response(&frame, 0, 1, 1, &bits));
    try std.testing.expectError(error.InvalidLength, decode_read_discrete_inputs_response(&frame, 0, 1, 1, &bits));
}
