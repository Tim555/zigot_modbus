//! Synchronous RTU transactions with caller-supplied serial transport.
const codec = @import("modbus_codec.zig");
const max_register_count = @import("modbus_tcp.zig").max_register_count;
const max_bit_count = @import("modbus_tcp.zig").max_bit_count;

/// The adapter owns serial configuration, RS-485 direction, deadlines, t1.5/t3.5,
/// and recovery/draining after errors. Exchange sends the entire request exactly
/// once and returns exactly one complete response ADU (including CRC), or errors.
/// It must reject truncated/extra frames and must not retry writes. On failure it
/// must restore a clean frame boundary before allowing another transaction.
/// Context and underlying port must outlive the client. Calls are synchronous.
pub const Transport = struct {
    context: *anyopaque,
    exchange: *const fn (*anyopaque, []const u8, []u8) anyerror!usize,
};

pub const Exception = struct {
    unit_id: u8,
    function_code: u8,
    exception_code: codec.ExceptionCode,
    raw_frame: [5]u8,
};

pub const Result = union(enum) {
    count: usize,
    exception: Exception,
};
const ReadResult = Result;
const WriteResult = Result;

/// Borrows the transport. One outstanding transaction per bus; no automatic
/// retry or broadcast support. The caller opens/closes the serial port.
pub const SyncRtuModbusClient = struct {
    transport: Transport,
    exception_frame: [5]u8 = undefined,

    pub fn init(transport: Transport) SyncRtuModbusClient {
        return .{ .transport = transport };
    }

    fn validateUnit(unit_id: u8) !void {
        if (unit_id == 0 or unit_id > 247) return error.InvalidUnitId;
    }

    fn makeException(self: *const SyncRtuModbusClient, exc: codec.ModbusException) Exception {
        return .{ .unit_id = exc.unit_id, .function_code = exc.function_code, .exception_code = exc.exception_code, .raw_frame = self.exception_frame };
    }

    /// Read 1–125 holding registers (FC03) in ascending address order.
    /// Requires out.len >= quantity; server exceptions become error.ModbusException.
    pub fn readHoldingRegister(self: *SyncRtuModbusClient, address: u16, quantity: u16, unit_id: u8, out: []u16) !usize {
        return switch (try self.readHoldingRegisterDetailed(address, quantity, unit_id, out)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    /// Same read and buffer contract, preserving the server exception in RtuResult.
    pub fn readHoldingRegisterDetailed(self: *SyncRtuModbusClient, address: u16, quantity: u16, unit_id: u8, out: []u16) !ReadResult {
        return self.readDetailed(0x03, address, quantity, unit_id, out);
    }

    /// Read 1–125 input registers (FC04) in ascending address order.
    /// Requires out.len >= quantity; server exceptions become error.ModbusException.
    pub fn readInputRegister(self: *SyncRtuModbusClient, address: u16, quantity: u16, unit_id: u8, out: []u16) !usize {
        return switch (try self.readInputRegisterDetailed(address, quantity, unit_id, out)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    /// Same read and buffer contract, preserving the server exception in RtuResult.
    pub fn readInputRegisterDetailed(self: *SyncRtuModbusClient, address: u16, quantity: u16, unit_id: u8, out: []u16) !ReadResult {
        return self.readDetailed(4, address, quantity, unit_id, out);
    }

    /// Read 1–2000 coils (FC01) in ascending address order.
    /// Requires out.len >= quantity; server exceptions become error.ModbusException.
    pub fn readCoils(self: *SyncRtuModbusClient, address: u16, quantity: u16, unit_id: u8, out: []bool) !usize {
        return switch (try self.readCoilsDetailed(address, quantity, unit_id, out)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    /// Same read and buffer contract, preserving the server exception in RtuResult.
    pub fn readCoilsDetailed(self: *SyncRtuModbusClient, address: u16, quantity: u16, unit_id: u8, out: []bool) !ReadResult {
        return self.readDetailed(1, address, quantity, unit_id, out);
    }

    /// Read 1–2000 discrete inputs (FC02) in ascending address order.
    /// Requires out.len >= quantity; server exceptions become error.ModbusException.
    pub fn readDiscreteInputs(self: *SyncRtuModbusClient, address: u16, quantity: u16, unit_id: u8, out: []bool) !usize {
        return switch (try self.readDiscreteInputsDetailed(address, quantity, unit_id, out)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    /// Same read and buffer contract, preserving the server exception in RtuResult.
    pub fn readDiscreteInputsDetailed(self: *SyncRtuModbusClient, address: u16, quantity: u16, unit_id: u8, out: []bool) !ReadResult {
        return self.readDetailed(2, address, quantity, unit_id, out);
    }

    // FC01/02 unpack bits into bools; FC03/04 decode big-endian u16 registers.
    fn readDetailed(self: *SyncRtuModbusClient, comptime function: u8, address: u16, quantity: u16, unit_id: u8, out: []if (function <= 2) bool else u16) !ReadResult {
        try validateUnit(unit_id);
        if (quantity == 0 or quantity > (if (function <= 2) max_bit_count else max_register_count)) return error.InvalidQuantity;
        if (@as(usize, address) + quantity > 65536) return error.InvalidAddressRange;
        if (out.len < quantity) return error.BufferTooSmall;

        const request_id: u16 = 0;
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
            return .{ .exception = self.makeException(exc) };
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
    pub fn writeSingleCoil(self: *SyncRtuModbusClient, address: u16, value: bool, unit_id: u8) !usize {
        return switch (try self.writeSingleCoilDetailed(address, value, unit_id)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    /// Same write contract, preserving the server exception in RtuResult.
    pub fn writeSingleCoilDetailed(self: *SyncRtuModbusClient, address: u16, value: bool, unit_id: u8) !WriteResult {
        try validateUnit(unit_id);
        var request: [codec.max_adu_length]u8 = undefined;
        const request_len = try codec.encode_write_single_coil_request(0, unit_id, address, value, &request);
        return self.writeDetailed(request[0..request_len], unit_id);
    }

    /// Write one holding register (FC06) at a zero-based wire address.
    /// Returns the acknowledged count; server exceptions become error.ModbusException.
    /// Writes are never retried automatically: an I/O failure may follow a completed write.
    pub fn writeSingleRegister(self: *SyncRtuModbusClient, address: u16, value: u16, unit_id: u8) !usize {
        return switch (try self.writeSingleRegisterDetailed(address, value, unit_id)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    /// Same write contract, preserving the server exception in RtuResult.
    pub fn writeSingleRegisterDetailed(self: *SyncRtuModbusClient, address: u16, value: u16, unit_id: u8) !WriteResult {
        try validateUnit(unit_id);
        var request: [codec.max_adu_length]u8 = undefined;
        const request_len = try codec.encode_write_single_register_request(0, unit_id, address, value, &request);
        return self.writeDetailed(request[0..request_len], unit_id);
    }

    /// Write 1–1968 coils (FC15) at a zero-based wire address.
    /// Returns the acknowledged count; server exceptions become error.ModbusException.
    /// Writes are never retried automatically: an I/O failure may follow a completed write.
    pub fn writeMultipleCoils(self: *SyncRtuModbusClient, address: u16, values: []const bool, unit_id: u8) !usize {
        return switch (try self.writeMultipleCoilsDetailed(address, values, unit_id)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    /// Same write contract, preserving the server exception in RtuResult.
    pub fn writeMultipleCoilsDetailed(self: *SyncRtuModbusClient, address: u16, values: []const bool, unit_id: u8) !WriteResult {
        try validateUnit(unit_id);
        var request: [codec.max_adu_length]u8 = undefined;
        const request_len = try codec.encode_write_multiple_coils_request(0, unit_id, address, values, &request);
        return self.writeDetailed(request[0..request_len], unit_id);
    }

    /// Write 1–123 holding registers (FC16) at a zero-based wire address.
    /// Returns the acknowledged count; server exceptions become error.ModbusException.
    /// Writes are never retried automatically: an I/O failure may follow a completed write.
    pub fn writeMultipleRegisters(self: *SyncRtuModbusClient, address: u16, values: []const u16, unit_id: u8) !usize {
        return switch (try self.writeMultipleRegistersDetailed(address, values, unit_id)) {
            .count => |count| count,
            .exception => error.ModbusException,
        };
    }

    /// Same write contract, preserving the server exception in RtuResult.
    pub fn writeMultipleRegistersDetailed(self: *SyncRtuModbusClient, address: u16, values: []const u16, unit_id: u8) !WriteResult {
        try validateUnit(unit_id);
        var request: [codec.max_adu_length]u8 = undefined;
        const request_len = try codec.encode_write_multiple_registers_request(0, unit_id, address, values, &request);
        return self.writeDetailed(request[0..request_len], unit_id);
    }

    fn writeDetailed(self: *SyncRtuModbusClient, request: []const u8, unit_id: u8) !WriteResult {
        const request_id: u16 = 0;
        var response: [codec.max_adu_length]u8 = undefined;
        const response_len = try self.exchange(request, request_id, unit_id, &response);
        const frame = response[0..response_len];
        const function = request[7];
        if ((frame[7] & 0x80) != 0) {
            const exception = try codec.decode_exception_response(frame, request_id, unit_id);
            if (exception.function_code != function) return error.InvalidFunctionCode;
            return .{ .exception = self.makeException(exception) };
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

    // A private MBAP envelope lets TCP and RTU share all PDU validation. No
    // invented TCP header/transaction metadata escapes through RTU results.
    fn exchange(self: *SyncRtuModbusClient, request: []const u8, request_id: u16, unit_id: u8, response: *[codec.max_adu_length]u8) !usize {
        var tx: [codec.max_rtu_adu_length]u8 = undefined;
        const tx_len = try codec.encode_rtu_frame(unit_id, request[7..], &tx);
        var rx: [codec.max_rtu_adu_length]u8 = undefined;
        const rx_len = try self.transport.exchange(self.transport.context, tx[0..tx_len], &rx);
        if (rx_len > rx.len) return error.ResponseTooLarge;
        const frame = try codec.decode_rtu_frame(rx[0..rx_len]);
        if (frame.unit_id != unit_id) return error.UnitIdMismatch;
        if (frame.pdu.len < 2) return error.InvalidLength;
        if ((frame.pdu[0] & 0x80) != 0 and rx_len == 5) {
            @memcpy(&self.exception_frame, rx[0..5]);
        }
        try codec.encode_mbap_header(request_id, 0, @intCast(frame.pdu.len + 1), unit_id, response);
        @memcpy(response[7 .. 7 + frame.pdu.len], frame.pdu);
        return 7 + frame.pdu.len;
    }
};
