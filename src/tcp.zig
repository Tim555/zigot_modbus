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

pub const ModbusException = struct {
    function_code: u8,
    exception_code: ExceptionCode,
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
    if (quantity == 0 or quantity > 125) return error.InvalidQuantity;
    if (out.len < mbap_header_length + 5) return error.BufferTooSmall;

    try encode_mbap_header(transaction_id, 0, 6, unit_id, out[0..mbap_header_length]);
    out[7] = 0x03;
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

    const exception_code = @as(ExceptionCode, @enumFromInt(frame[8]));
    return ModbusException{
        .function_code = function_code & 0x7f,
        .exception_code = exception_code,
    };
}

pub fn decode_read_holding_registers_response(frame: []const u8, expected_transaction_id: u16, expected_unit_id: u8, out: []u16) !usize {
    const header = try decode_mbap_header(frame);

    if (header.transaction_id != expected_transaction_id) return error.TransactionIdMismatch;
    if (header.protocol_id != 0) return error.InvalidProtocolId;
    if (header.unit_id != expected_unit_id) return error.UnitIdMismatch;
    if (header.length < 3) return error.InvalidLength;
    if (frame.len != 6 + header.length) return error.InvalidLength;
    if (frame.len < 9) return error.InvalidLength;

    const function_code = frame[7];
    if ((function_code & 0x80) != 0) {
        _ = try decode_exception_response(frame, expected_transaction_id, expected_unit_id);
        return error.ModbusException;
    }
    if (function_code != 0x03) return error.InvalidFunctionCode;

    const byte_count = frame[8];
    if (byte_count == 0 or (byte_count % 2) != 0) return error.InvalidByteCount;
    if (frame.len != 9 + byte_count) return error.InvalidLength;
    if (out.len < (byte_count / 2)) return error.BufferTooSmall;

    for (0..(byte_count / 2)) |index| {
        const offset = 9 + index * 2;
        out[index] = @as(u16, @intCast(((@as(u16, frame[offset]) << 8) | @as(u16, frame[offset + 1]))));
    }

    return byte_count / 2;
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
}
