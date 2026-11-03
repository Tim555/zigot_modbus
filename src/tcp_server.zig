//! Concurrent Modbus TCP server. Framing is per connection; datastore operations
//! are serialized so multi-value reads and writes cannot observe partial updates.
const std = @import("std");
const codec = @import("modbus_codec.zig");
const TcpClient = @import("tcp_transport.zig").TcpClient;

/// Tables start at wire address zero. Empty tables reject all addresses.
/// Storage must outlive the server. Do not mutate slices or table contents while
/// serve runs unless holding the server's data_mutex with the same Io backend.
pub const Device = struct {
    unit_id: u8,
    coils: []bool = &.{},
    discrete_inputs: []const bool = &.{},
    holding_registers: []u16 = &.{},
    input_registers: []const u16 = &.{},
};

pub const Options = struct {
    /// Excess connections wait in the OS listen backlog until a slot is free.
    max_clients: usize = 64,
    /// Deadline per complete header/payload receive, including partial reads.
    read_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
    /// Deadline for sending a complete response. Use .none to disable either timeout.
    write_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
};

/// Owns a listener and borrows device storage. Do not copy after starting serve.
/// Run serve via io.concurrent; cancel/join that future before calling deinit.
pub const TcpServer = struct {
    io: std.Io,
    listener: std.Io.net.Server,
    devices: []const Device,
    options: Options,
    data_mutex: std.Io.Mutex = .init,

    /// Bind an IP literal; port zero selects a free port, available via port().
    pub fn init(io: std.Io, host: []const u8, listen_port: u16, devices: []const Device, options: Options) !TcpServer {
        if (options.max_clients == 0) return error.InvalidMaxClients;
        for (devices, 0..) |device, index| {
            if (device.coils.len > 65536 or device.discrete_inputs.len > 65536 or device.holding_registers.len > 65536 or device.input_registers.len > 65536) return error.InvalidTableSize;
            for (devices[0..index]) |previous| {
                if (previous.unit_id == device.unit_id) return error.DuplicateUnitId;
            }
        }
        const address = try std.Io.net.IpAddress.parse(host, listen_port);
        return .{ .io = io, .listener = try address.listen(io, .{}), .devices = devices, .options = options };
    }

    pub fn port(self: *const TcpServer) u16 {
        return self.listener.socket.address.getPort();
    }

    /// Call only after serve has returned and all client tasks have joined.
    pub fn deinit(self: *TcpServer) void {
        self.listener.deinit(self.io);
    }

    /// Call only once at a time. One concurrent task per client; requests on each socket stay in wire order.
    /// Cancellation joins every client task and closes all accepted sockets.
    pub fn serve(self: *TcpServer) !void {
        var clients: std.Io.Group = .init;
        defer clients.cancel(self.io);
        var slots: std.Io.Semaphore = .{ .permits = self.options.max_clients };
        while (true) {
            try slots.wait(self.io);
            const peer = self.listener.accept(self.io) catch |err| {
                slots.post(self.io);
                return err;
            };
            clients.concurrent(self.io, serveClient, .{ self, peer, &slots }) catch |err| {
                peer.close(self.io);
                slots.post(self.io);
                return err;
            };
        }
    }

    fn serveClient(self: *TcpServer, peer: std.Io.net.Stream, slots: *std.Io.Semaphore) std.Io.Cancelable!void {
        defer slots.post(self.io);
        // Transfer the accepted socket into the existing timeout-aware transport.
        var transport = TcpClient.initWithOptions(self.io, .{ .read_timeout = self.options.read_timeout, .write_timeout = self.options.write_timeout });
        transport.connection = peer;
        defer transport.disconnect();
        self.session(&transport) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {}, // A bad/disconnected peer must not stop the listener.
        };
    }

    fn session(self: *TcpServer, transport: *TcpClient) !void {
        while (true) {
            var request: [codec.max_adu_length]u8 = undefined;
            try transport.receiveExact(request[0..codec.mbap_header_length]);
            const header = try codec.decode_mbap_header(request[0..codec.mbap_header_length]);
            // Invalid framing closes this connection: its next frame boundary is untrusted.
            if (header.protocol_id != 0 or header.length < 2 or header.length > 254) return error.InvalidHeader;
            const length = 6 + @as(usize, header.length);
            try transport.receiveExact(request[codec.mbap_header_length..length]);
            var response: [codec.max_adu_length]u8 = undefined;
            const response_length = try self.respond(header, request[7..length], &response);
            try transport.send(response[0..response_length]);
        }
    }

    fn respond(self: *TcpServer, header: codec.MbapHeader, pdu: []const u8, out: []u8) !usize {
        var exception: codec.ExceptionCode = .gateway_target_device_failed_to_respond;
        var pdu_length: ?usize = null;
        {
            try self.data_mutex.lock(self.io);
            defer self.data_mutex.unlock(self.io);
            for (self.devices) |device| {
                if (device.unit_id != header.unit_id) continue;
                pdu_length = handlePdu(device, pdu, out[7..]) catch |err| blk: {
                    exception = switch (err) {
                        error.IllegalFunction => .illegal_function,
                        error.IllegalAddress => .illegal_data_address,
                        error.IllegalValue => .illegal_data_value,
                    };
                    break :blk null;
                };
                break;
            }
        }
        // Release the datastore lock before socket I/O; slow peers cannot hold it.
        if (pdu_length == null) {
            out[7] = pdu[0] | 0x80;
            out[8] = @backingInt(exception);
            pdu_length = 2;
        }
        try codec.encode_mbap_header(header.transaction_id, 0, @intCast(pdu_length.? + 1), header.unit_id, out);
        return 7 + pdu_length.?;
    }
};

fn word(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn putWord(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @intCast(value >> 8);
    bytes[offset + 1] = @truncate(value);
}

fn checkRange(address: usize, quantity: usize, table_length: usize) error{IllegalAddress}!void {
    if (address + quantity > 65536 or address + quantity > table_length) return error.IllegalAddress;
}

/// Validate the entire write before touching storage, under the caller's mutex.
fn handlePdu(device: Device, pdu: []const u8, out: []u8) error{ IllegalFunction, IllegalAddress, IllegalValue }!usize {
    const function = pdu[0];
    switch (function) {
        1, 2, 3, 4, 5, 6 => if (pdu.len != 5) return error.IllegalValue,
        15, 16 => if (pdu.len < 6) return error.IllegalValue,
        else => return error.IllegalFunction,
    }
    const address: usize = word(pdu, 1);
    const value = word(pdu, 3);
    out[0] = function;
    switch (function) {
        1, 2 => {
            if (value == 0 or value > 2000) return error.IllegalValue;
            const table: []const bool = if (function == 1) device.coils else device.discrete_inputs;
            try checkRange(address, value, table.len);
            const bytes = (@as(usize, value) + 7) / 8;
            out[1] = @intCast(bytes);
            @memset(out[2 .. 2 + bytes], 0);
            for (table[address .. address + value], 0..) |bit, index| {
                if (bit) out[2 + index / 8] |= @as(u8, 1) << @as(u3, @intCast(index % 8));
            }
            return 2 + bytes;
        },
        3, 4 => {
            if (value == 0 or value > 125) return error.IllegalValue;
            const table: []const u16 = if (function == 3) device.holding_registers else device.input_registers;
            try checkRange(address, value, table.len);
            out[1] = @intCast(@as(usize, value) * 2);
            for (table[address .. address + value], 0..) |register, index| putWord(out, 2 + index * 2, register);
            return 2 + @as(usize, value) * 2;
        },
        5 => {
            if (value != 0 and value != 0xff00) return error.IllegalValue;
            try checkRange(address, 1, device.coils.len);
            device.coils[address] = value != 0;
        },
        6 => {
            try checkRange(address, 1, device.holding_registers.len);
            device.holding_registers[address] = value;
        },
        15, 16 => {
            const limit: u16 = if (function == 15) 1968 else 123;
            if (value == 0 or value > limit) return error.IllegalValue;
            const bytes = if (function == 15) (@as(usize, value) + 7) / 8 else @as(usize, value) * 2;
            if (pdu[5] != bytes or pdu.len != 6 + bytes) return error.IllegalValue;
            const table_length = if (function == 15) device.coils.len else device.holding_registers.len;
            try checkRange(address, value, table_length);
            for (0..value) |index| {
                if (function == 15) {
                    device.coils[address + index] = (pdu[6 + index / 8] & (@as(u8, 1) << @as(u3, @intCast(index % 8)))) != 0;
                } else device.holding_registers[address + index] = word(pdu, 6 + index * 2);
            }
        },
        else => unreachable,
    }
    std.mem.copyForwards(u8, out[1..5], pdu[1..5]);
    return 5;
}

test "malformed writes do not partially modify storage" {
    var registers = [_]u16{ 1, 2 };
    var coils = [_]bool{ false, true };
    const device: Device = .{ .unit_id = 1, .holding_registers = &registers, .coils = &coils };
    var out: [253]u8 = undefined;
    try std.testing.expectError(error.IllegalValue, handlePdu(device, &.{ 16, 0, 0, 0, 2, 4, 0, 3 }, &out));
    try std.testing.expectError(error.IllegalAddress, handlePdu(device, &.{ 16, 0, 1, 0, 2, 4, 0, 3, 0, 4 }, &out));
    try std.testing.expectError(error.IllegalValue, handlePdu(device, &.{ 5, 0, 0, 0, 1 }, &out));
    try std.testing.expectError(error.IllegalValue, handlePdu(device, &.{ 15, 0, 0, 0, 2, 2, 3, 0 }, &out));
    try std.testing.expectError(error.IllegalFunction, handlePdu(device, &.{0x41}, &out));
    try std.testing.expectEqualSlices(u16, &.{ 1, 2 }, &registers);
    try std.testing.expectEqualSlices(bool, &.{ false, true }, &coils);
}

test "server rejects invalid configuration before binding" {
    try std.testing.expectError(error.InvalidMaxClients, TcpServer.init(std.testing.io, "127.0.0.1", 0, &.{}, .{ .max_clients = 0 }));
    try std.testing.expectError(error.DuplicateUnitId, TcpServer.init(std.testing.io, "127.0.0.1", 0, &.{ .{ .unit_id = 1 }, .{ .unit_id = 1 } }, .{}));
}
