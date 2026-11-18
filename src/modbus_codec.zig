//! Modbus TCP/RTU framing, PDU codecs, and CRC-16/MODBUS. No transport I/O.
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
    normal_response,
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

/// Encode FC03 for 1–125 holding registers at a zero-based wire address.
/// Requires 12 output bytes and returns the encoded frame length.
pub fn encode_read_holding_registers_request(transaction_id: u16, unit_id: u8, address: u16, quantity: u16, out: []u8) !usize {
    return encode_read_request(3, 125, transaction_id, unit_id, address, quantity, out);
}

/// Encode FC04 for 1–125 input registers at a zero-based wire address.
/// Requires 12 output bytes and returns the encoded frame length.
pub fn encode_read_input_registers_request(transaction_id: u16, unit_id: u8, address: u16, quantity: u16, out: []u8) !usize {
    return encode_read_request(4, 125, transaction_id, unit_id, address, quantity, out);
}

/// Encode FC01 for 1–2000 coils at a zero-based wire address.
/// Requires 12 output bytes and returns the encoded frame length.
pub fn encode_read_coils_request(transaction_id: u16, unit_id: u8, address: u16, quantity: u16, out: []u8) !usize {
    return encode_read_request(1, 2000, transaction_id, unit_id, address, quantity, out);
}

/// Encode FC02 for 1–2000 discrete inputs at a zero-based wire address.
/// Requires 12 output bytes and returns the encoded frame length.
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

/// Maximum values in FC15/FC16 requests (their PDUs include a byte-count field).
pub const max_write_coil_count: usize = 1968;
pub const max_write_register_count: usize = 123;

fn put_u16(out: []u8, offset: usize, value: u16) void {
    out[offset] = @intCast(value >> 8);
    out[offset + 1] = @truncate(value);
}

fn get_u16(frame: []const u8, offset: usize) u16 {
    return (@as(u16, frame[offset]) << 8) | frame[offset + 1];
}

/// Encode FC05. True is represented by 0xff00, false by 0x0000.
pub fn encode_write_single_coil_request(transaction_id: u16, unit_id: u8, address: u16, value: bool, out: []u8) !usize {
    return encode_write_single_request(5, transaction_id, unit_id, address, if (value) 0xff00 else 0, out);
}

/// Encode FC06 with a big-endian holding-register value.
pub fn encode_write_single_register_request(transaction_id: u16, unit_id: u8, address: u16, value: u16, out: []u8) !usize {
    return encode_write_single_request(6, transaction_id, unit_id, address, value, out);
}

fn encode_write_single_request(function: u8, transaction_id: u16, unit_id: u8, address: u16, value: u16, out: []u8) !usize {
    if (out.len < 12) return error.BufferTooSmall;
    try encode_mbap_header(transaction_id, 0, 6, unit_id, out);
    out[7] = function;
    put_u16(out, 8, address);
    put_u16(out, 10, value);
    return 12;
}

/// Encode FC15, packing 1–1968 coils LSB first and zeroing final-byte padding.
pub fn encode_write_multiple_coils_request(transaction_id: u16, unit_id: u8, address: u16, values: []const bool, out: []u8) !usize {
    return encode_write_multiple_request(15, transaction_id, unit_id, address, values, out);
}

/// Encode FC16 for 1–123 holding registers in ascending address order.
pub fn encode_write_multiple_registers_request(transaction_id: u16, unit_id: u8, address: u16, values: []const u16, out: []u8) !usize {
    return encode_write_multiple_request(16, transaction_id, unit_id, address, values, out);
}

fn encode_write_multiple_request(comptime function: u8, transaction_id: u16, unit_id: u8, address: u16, values: []const if (function == 15) bool else u16, out: []u8) !usize {
    const limit = if (function == 15) max_write_coil_count else max_write_register_count;
    if (values.len == 0 or values.len > limit) return error.InvalidQuantity;
    if (@as(usize, address) + values.len > 65536) return error.InvalidAddressRange;
    const byte_count = if (function == 15) (values.len + 7) / 8 else values.len * 2;
    const length = 13 + byte_count;
    if (out.len < length) return error.BufferTooSmall;
    try encode_mbap_header(transaction_id, 0, @intCast(length - 6), unit_id, out);
    out[7] = function;
    put_u16(out, 8, address);
    put_u16(out, 10, @intCast(values.len));
    out[12] = @intCast(byte_count);
    if (function == 15) {
        @memset(out[13..length], 0);
        for (values, 0..) |value, index| {
            if (value) out[13 + index / 8] |= @as(u8, 1) << @as(u3, @intCast(index % 8));
        }
    } else {
        for (values, 0..) |value, index| put_u16(out, 13 + index * 2, value);
    }
    return length;
}

/// Validate the complete acknowledgment, including the echoed address and value.
/// Returns the acknowledged element count; matching exceptions return error.ModbusException.
pub fn decode_write_single_coil_response(frame: []const u8, expected_transaction_id: u16, expected_unit_id: u8, address: u16, value: bool) !usize {
    return decode_write_response(5, frame, expected_transaction_id, expected_unit_id, address, if (value) 0xff00 else 0);
}

/// Validate the complete acknowledgment, including the echoed address and value.
/// Returns the acknowledged element count; matching exceptions return error.ModbusException.
pub fn decode_write_single_register_response(frame: []const u8, expected_transaction_id: u16, expected_unit_id: u8, address: u16, value: u16) !usize {
    return decode_write_response(6, frame, expected_transaction_id, expected_unit_id, address, value);
}

/// Validate the complete acknowledgment, including the echoed address and quantity.
/// Returns the acknowledged element count; matching exceptions return error.ModbusException.
pub fn decode_write_multiple_coils_response(frame: []const u8, expected_transaction_id: u16, expected_unit_id: u8, address: u16, quantity: u16) !usize {
    if (quantity == 0 or quantity > max_write_coil_count) return error.InvalidQuantity;
    if (@as(usize, address) + quantity > 65536) return error.InvalidAddressRange;
    return decode_write_response(15, frame, expected_transaction_id, expected_unit_id, address, quantity);
}

/// Validate the complete acknowledgment, including the echoed address and quantity.
/// Returns the acknowledged element count; matching exceptions return error.ModbusException.
pub fn decode_write_multiple_registers_response(frame: []const u8, expected_transaction_id: u16, expected_unit_id: u8, address: u16, quantity: u16) !usize {
    if (quantity == 0 or quantity > max_write_register_count) return error.InvalidQuantity;
    if (@as(usize, address) + quantity > 65536) return error.InvalidAddressRange;
    return decode_write_response(16, frame, expected_transaction_id, expected_unit_id, address, quantity);
}

fn decode_write_response(function: u8, frame: []const u8, expected_transaction_id: u16, expected_unit_id: u8, address: u16, value_or_quantity: u16) !usize {
    const header = try decode_mbap_header(frame);
    if (header.transaction_id != expected_transaction_id) return error.TransactionIdMismatch;
    if (header.protocol_id != 0) return error.InvalidProtocolId;
    if (header.unit_id != expected_unit_id) return error.UnitIdMismatch;
    if (header.length < 3 or frame.len != 6 + @as(usize, header.length)) return error.InvalidLength;
    if (frame[7] == (function | 0x80)) {
        _ = try decode_exception_response(frame, expected_transaction_id, expected_unit_id);
        return error.ModbusException;
    }
    if (frame[7] != function) return error.InvalidFunctionCode;
    if (header.length != 6) return error.InvalidLength;
    if (get_u16(frame, 8) != address) return error.AddressMismatch;
    if (get_u16(frame, 10) != value_or_quantity) return error.WriteEchoMismatch;
    return if (function == 5 or function == 6) 1 else value_or_quantity;
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

/// Classify TCP response framing and exceptions. A normal_response has a matching
/// MBAP header and a non-exception function code. Use the function-specific decoder
/// to validate its contents against the request.
/// Oversized TCP ADUs are malformed. The diagnostic retains at most one PDU's worth of payload.
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
    const preview_end = @min(frame.len, max_adu_length);
    const pdu_len = preview_end - mbap_header_length;
    std.mem.copyForwards(u8, pdu[0..pdu_len], frame[mbap_header_length..preview_end]);
    if (frame.len > max_adu_length) {
        return .{
            .kind = .malformed_response,
            .transaction_id = header.transaction_id,
            .protocol_id = header.protocol_id,
            .unit_id = header.unit_id,
            .header = header,
            .pdu = pdu,
            .pdu_len = pdu_len,
            .message = "Frame exceeds maximum TCP ADU length",
        };
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

    const kind: ModbusErrorKind = if (frame.len != 6 + @as(usize, header.length))
        .invalid_length
    else if (function_code == 0)
        .invalid_function_code
    else
        .normal_response;
    return ModbusFrameError{
        .kind = kind,
        .transaction_id = header.transaction_id,
        .protocol_id = header.protocol_id,
        .unit_id = header.unit_id,
        .header = header,
        .pdu = pdu,
        .pdu_len = pdu_len,
        .function_code = function_code,
        .message = switch (kind) {
            .invalid_length => "Frame size does not match MBAP length",
            .invalid_function_code => "Function code zero is invalid",
            .normal_response => "Normal Modbus response",
            else => unreachable,
        },
    };
}

/// Validate a complete response and decode big-endian registers into out.
/// Returns the response count; the caller must compare it with the requested quantity.
/// Matching server exceptions return error.ModbusException.
pub fn decode_read_holding_registers_response(frame: []const u8, expected_transaction_id: u16, expected_unit_id: u8, out: []u16) !usize {
    return decode_read_registers_response(3, frame, expected_transaction_id, expected_unit_id, out);
}

/// Validate a complete response and decode big-endian registers into out.
/// Returns the response count; the caller must compare it with the requested quantity.
/// Matching server exceptions return error.ModbusException.
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
    // Widen before adding: untrusted u16 lengths may be close to 65535.
    if (frame.len != 6 + @as(usize, header.length)) return error.InvalidLength;
    if (frame.len < 9) return error.InvalidLength;

    const function_code = frame[7];
    if ((function_code & 0x80) != 0) {
        const exc = try decode_exception_response(frame, expected_transaction_id, expected_unit_id);
        if (exc.function_code != expected_function) return error.InvalidFunctionCode;
        return error.ModbusException;
    }
    if (function_code != expected_function) return error.InvalidFunctionCode;

    // A valid 125-register response has 250 data bytes; adding its prefix in u8 overflows.
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
    // The response carries only a byte count, so quantity determines which trailing bits are padding.
    const byte_count = (@as(usize, quantity) + 7) / 8;
    if (frame[8] != byte_count) return error.InvalidByteCount;
    if (frame.len != 9 + byte_count) return error.InvalidLength;
    if (out.len < quantity) return error.BufferTooSmall;
    for (0..quantity) |index| {
        out[index] = (frame[9 + index / 8] & (@as(u8, 1) << @as(u3, @intCast(index % 8)))) != 0;
    }
    return quantity;
}

test "diagnostic decoder bounds the payload preview for oversized ADUs" {
    var frame: [max_adu_length + 32]u8 = undefined;
    @memset(&frame, 0xa5);
    try encode_mbap_header(42, 0, 254, 7, &frame);
    const result = decode_modbus_error(&frame, 42, 7);
    try std.testing.expectEqual(ModbusErrorKind.malformed_response, result.kind);
    try std.testing.expectEqual(@as(u16, 42), result.transaction_id);
    try std.testing.expectEqual(@as(u8, 7), result.unit_id);
    try std.testing.expectEqualSlices(u8, frame[mbap_header_length..max_adu_length], result.pdu[0..result.pdu_len]);

    const one_extra = decode_modbus_error(frame[0 .. max_adu_length + 1], 42, 7);
    try std.testing.expectEqual(ModbusErrorKind.malformed_response, one_extra.kind);
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

test "diagnostic decoder classifies normal responses across function codes" {
    const cases = [_][5]u8{
        .{ 1, 1, 1, 0, 0 },
        .{ 2, 1, 1, 0, 0 },
        .{ 3, 2, 0, 1, 0 },
        .{ 4, 2, 0, 1, 0 },
        .{ 5, 0, 0, 0xff, 0 },
        .{ 6, 0, 0, 0, 1 },
        .{ 15, 0, 0, 0, 1 },
        .{ 16, 0, 0, 0, 1 },
    };
    for (cases) |pdu| {
        const pdu_length: usize = switch (pdu[0]) {
            1, 2 => 3,
            3, 4 => 4,
            else => 5,
        };
        var frame: [mbap_header_length + 5]u8 = undefined;
        try encode_mbap_header(42, 0, @intCast(pdu_length + 1), 7, &frame);
        @memcpy(frame[mbap_header_length..], &pdu);
        const frame_length = mbap_header_length + pdu_length;
        const result = decode_modbus_error(frame[0..frame_length], 42, 7);
        try std.testing.expectEqual(ModbusErrorKind.normal_response, result.kind);
        try std.testing.expectEqual(@as(?u8, pdu[0]), result.function_code);
        try std.testing.expectEqual(@as(?ExceptionCode, null), result.exception_code);
        try std.testing.expectEqualSlices(u8, pdu[0..pdu_length], result.pdu[0..result.pdu_len]);
        try std.testing.expectEqual(ModbusErrorKind.invalid_length, decode_modbus_error(frame[0 .. frame_length - 1], 42, 7).kind);
    }
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

test "write request wire formats and padding" {
    var out: [max_adu_length]u8 = @splat(0xff);
    try std.testing.expectEqual(@as(usize, 12), try encode_write_single_coil_request(0x1234, 7, 0xabcd, true, &out));
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0, 0, 0, 6, 7, 5, 0xab, 0xcd, 0xff, 0 }, out[0..12]);
    _ = try encode_write_single_coil_request(0, 1, 0, false, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, out[10..12]);
    _ = try encode_write_single_register_request(0, 1, 10, 0x8001, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 6, 1, 6, 0, 10, 0x80, 1 }, out[0..12]);
    const coils = [_]bool{ true, false, false, false, false, false, false, true, true };
    try std.testing.expectEqual(@as(usize, 15), try encode_write_multiple_coils_request(0, 1, 7, &coils, &out));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 9, 1, 15, 0, 7, 0, 9, 2, 0x81, 1 }, out[0..15]);
    try std.testing.expectEqual(@as(usize, 17), try encode_write_multiple_registers_request(0, 1, 10, &.{ 0x1234, 0xabcd }, &out));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 11, 1, 16, 0, 10, 0, 2, 4, 0x12, 0x34, 0xab, 0xcd }, out[0..17]);
}

test "write encoders validate quantities, address ranges and output capacity" {
    var out: [max_adu_length]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, encode_write_single_coil_request(0, 1, 0, true, out[0..11]));
    try std.testing.expectError(error.BufferTooSmall, encode_write_single_register_request(0, 1, 0, 1, out[0..11]));
    inline for (.{ encode_write_multiple_coils_request, encode_write_multiple_registers_request }, .{ bool, u16 }, .{ max_write_coil_count, max_write_register_count }) |encode, T, limit| {
        const values: [limit + 1]T = @splat(if (T == bool) true else 0xffff);
        try std.testing.expectError(error.InvalidQuantity, encode(0, 1, 0, values[0..0], &out));
        try std.testing.expectError(error.InvalidQuantity, encode(0, 1, 0, &values, &out));
        try std.testing.expectError(error.InvalidAddressRange, encode(0, 1, 65535, values[0..2], &out));
        try std.testing.expectError(error.BufferTooSmall, encode(0, 1, 0, values[0..limit], out[0..258]));
        try std.testing.expectEqual(@as(usize, 259), try encode(0, 1, 0, values[0..limit], &out));
        _ = try encode(0, 1, 65535, values[0..1], &out);
    }
}

test "write acknowledgments reject mismatches and preserve exception errors" {
    inline for (.{ decode_write_single_coil_response, decode_write_single_register_response, decode_write_multiple_coils_response, decode_write_multiple_registers_response }, .{ @as(u8, 5), @as(u8, 6), @as(u8, 15), @as(u8, 16) }) |decode, function| {
        const expected = if (function == 5) true else @as(u16, 9);
        const wire_value: u16 = if (function == 5) 0xff00 else 9;
        var frame = [_]u8{ 0, 1, 0, 0, 0, 6, 7, function, 0, 10, @intCast(wire_value >> 8), @truncate(wire_value) };
        try std.testing.expectEqual(@as(usize, if (function <= 6) 1 else 9), try decode(&frame, 1, 7, 10, expected));
        try std.testing.expectError(error.TransactionIdMismatch, decode(&frame, 2, 7, 10, expected));
        try std.testing.expectError(error.UnitIdMismatch, decode(&frame, 1, 1, 10, expected));
        frame[3] = 1;
        try std.testing.expectError(error.InvalidProtocolId, decode(&frame, 1, 7, 10, expected));
        frame[3] = 0;
        try std.testing.expectError(error.AddressMismatch, decode(&frame, 1, 7, 11, expected));
        frame[11] ^= 1;
        try std.testing.expectError(error.WriteEchoMismatch, decode(&frame, 1, 7, 10, expected));
        frame[11] ^= 1;
        try std.testing.expectError(error.InvalidLength, decode(frame[0..11], 1, 7, 10, expected));
        frame[7] = 3;
        try std.testing.expectError(error.InvalidFunctionCode, decode(&frame, 1, 7, 10, expected));
        frame[7] = function | 0x80;
        frame[5] = 3;
        frame[8] = 2;
        try std.testing.expectError(error.ModbusException, decode(frame[0..9], 1, 7, 10, expected));
        frame[7] = 0x84;
        try std.testing.expectError(error.InvalidFunctionCode, decode(frame[0..9], 1, 7, 10, expected));
    }
}

test "multiple-write decoders reject impossible expected quantities and ranges" {
    inline for (.{ decode_write_multiple_coils_response, decode_write_multiple_registers_response }, .{ @as(u16, 1968), @as(u16, 123) }) |decode, limit| {
        try std.testing.expectError(error.InvalidQuantity, decode(&.{}, 0, 1, 0, 0));
        try std.testing.expectError(error.InvalidQuantity, decode(&.{}, 0, 1, 0, limit + 1));
        try std.testing.expectError(error.InvalidAddressRange, decode(&.{}, 0, 1, 65535, 2));
    }
}

/// CRC-16/MODBUS. RTU frames transmit the low byte first.
pub fn crc16(bytes: []const u8) u16 {
    var crc: u16 = 0xffff;
    for (bytes) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            crc = if (crc & 1 != 0) (crc >> 1) ^ 0xa001 else crc >> 1;
        }
    }
    return crc;
}

test "CRC-16/MODBUS check value" {
    try std.testing.expectEqual(@as(u16, 0x4b37), crc16("123456789"));
    try std.testing.expectEqual(@as(u16, 0xffff), crc16(""));
}

pub const max_rtu_adu_length: usize = 256;

pub const RtuFrame = struct {
    unit_id: u8,
    pdu: []const u8,
};

/// Encode address + PDU + low-byte-first CRC. PDU must include a function byte.
/// Input and output buffers must not overlap.
pub fn encode_rtu_frame(unit_id: u8, pdu: []const u8, out: []u8) !usize {
    if (pdu.len == 0 or pdu.len > 253) return error.InvalidLength;
    if (out.len < pdu.len + 3) return error.BufferTooSmall;
    out[0] = unit_id;
    @memcpy(out[1 .. 1 + pdu.len], pdu);
    const checksum = crc16(out[0 .. 1 + pdu.len]);
    out[1 + pdu.len] = @truncate(checksum);
    out[2 + pdu.len] = @truncate(checksum >> 8);
    return pdu.len + 3;
}

/// Verify a complete RTU ADU. Returned PDU borrows the input frame.
pub fn decode_rtu_frame(frame: []const u8) !RtuFrame {
    if (frame.len < 4 or frame.len > max_rtu_adu_length) return error.InvalidLength;
    const end = frame.len - 2;
    const checksum = @as(u16, frame[end]) | (@as(u16, frame[end + 1]) << 8);
    if (crc16(frame[0..end]) != checksum) return error.InvalidCrc;
    return .{ .unit_id = frame[0], .pdu = frame[1..end] };
}

test "RTU frame known vector, CRC byte order, and length bounds" {
    const known = [_]u8{ 1, 3, 0, 0, 0, 10, 0xc5, 0xcd };
    var out: [max_rtu_adu_length]u8 = undefined;
    const n = try encode_rtu_frame(1, known[1..6], &out);
    try std.testing.expectEqualSlices(u8, &known, out[0..n]);
    const decoded = try decode_rtu_frame(&known);
    try std.testing.expectEqual(@as(u8, 1), decoded.unit_id);
    try std.testing.expectEqualSlices(u8, known[1..6], decoded.pdu);
    out[n - 1] ^= 1;
    try std.testing.expectError(error.InvalidCrc, decode_rtu_frame(out[0..n]));
    for (0..4) |len| try std.testing.expectError(error.InvalidLength, decode_rtu_frame(known[0..len]));
    try std.testing.expectError(error.InvalidLength, encode_rtu_frame(1, &.{}, &out));
    const large: [257]u8 = @splat(0);
    try std.testing.expectError(error.InvalidLength, decode_rtu_frame(&large));
    try std.testing.expectError(error.InvalidLength, encode_rtu_frame(1, large[0..254], &out));
    try std.testing.expectError(error.BufferTooSmall, encode_rtu_frame(1, &.{3}, out[0..3]));
    try std.testing.expectEqual(@as(usize, 256), try encode_rtu_frame(247, large[0..253], &out));
    _ = try decode_rtu_frame(&out);
}
