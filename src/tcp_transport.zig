//! Blocking TCP byte-stream transport, independent of application protocols.
const std = @import("std");

/// Owns one socket. Initialize with init(io), and defer disconnect after connecting.
/// The caller-owned Io backend must outlive this client.
/// Do not copy a connected client or use it concurrently from multiple threads.
/// I/O is synchronous with configurable timeouts. Message framing belongs to
/// the caller: one send does not necessarily correspond to one receive.
pub const TcpClient = struct {
    io: std.Io,
    connection: ?std.Io.net.Stream = null,
    options: Options = .{},

    pub const Options = struct {
        connect_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
        read_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
        write_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } },
    };

    pub fn init(io: std.Io) TcpClient {
        return initWithOptions(io, .{});
    }

    /// Durations are per operation, not per partial read/write. Use .none to
    /// disable a timeout, or .deadline to share a deadline across operations.
    pub fn initWithOptions(io: std.Io, options: Options) TcpClient {
        return .{ .io = io, .options = options };
    }

    /// Connect to an IPv4 or IPv6 literal (not a DNS hostname).
    pub fn connect(self: *TcpClient, host: []const u8, port: u16) !void {
        if (self.isConnected()) return error.AlreadyConnected;
        const address = try std.Io.net.IpAddress.parse(host, port);
        const deadline = self.options.connect_timeout.toDeadline(self.io);
        try self.checkDeadline(deadline);
        self.connection = try self.connectWithDeadline(address, deadline);
    }

    fn connectWithoutTimeout(io: std.Io, address: std.Io.net.IpAddress) std.Io.net.IpAddress.ConnectError!std.Io.net.Stream {
        return address.connect(io, .{
            .mode = .stream,
            .protocol = .tcp,
        });
    }

    fn connectWithDeadline(self: *TcpClient, address: std.Io.net.IpAddress, deadline: std.Io.Timeout) !std.Io.net.Stream {
        if (deadline == .none) return connectWithoutTimeout(self.io, address);

        // Threaded's native connect timeout is unimplemented in Zig 0.17.
        // Race a cancelable connect against a timer without that socket option.
        const Result = union(enum) {
            connection: std.Io.net.IpAddress.ConnectError!std.Io.net.Stream,
            timer: std.Io.Cancelable!void,
        };
        var results: [2]Result = undefined;
        var select = std.Io.Select(Result).init(self.io, &results);
        defer {
            // Connect may succeed concurrently with the timeout/cancellation.
            // Drain and close any socket that was not returned to the caller.
            while (select.cancel()) |result| {
                switch (result) {
                    .connection => |connection| {
                        if (connection) |stream| stream.close(self.io) else |_| {}
                    },
                    .timer => {},
                }
            }
        }
        try select.concurrent(.connection, connectWithoutTimeout, .{ self.io, address });
        try select.concurrent(.timer, std.Io.Timeout.sleep, .{ deadline, self.io });
        switch (try select.await()) {
            .connection => |connection| return connection,
            .timer => |result| {
                try result;
                return error.Timeout;
            },
        }
    }

    /// Idempotent; also called automatically on I/O errors, timeouts, or EOF.
    pub fn disconnect(self: *TcpClient) void {
        if (self.connection) |connection| connection.close(self.io);
        self.connection = null;
    }

    /// Reports local socket ownership, not a probe of remote peer health.
    pub fn isConnected(self: *const TcpClient) bool {
        return self.connection != null;
    }

    /// Send all bytes within one write timeout. On failure, some bytes may
    /// already have been sent; the connection is closed and never auto-retried.
    pub fn send(self: *TcpClient, bytes: []const u8) !void {
        const connection = self.connection orelse return error.NotConnected;
        errdefer self.disconnect();
        if (bytes.len == 0) return;
        const deadline = self.options.write_timeout.toDeadline(self.io);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const slices = [_][]const u8{bytes[offset..]};
            const count = try (try self.operateWithDeadline(.{ .net_write = .{
                .socket_handle = connection.socket.handle,
                .data = &slices,
            } }, deadline)).net_write;
            if (count == 0) return error.WriteZero;
            offset += count;
        }
    }

    /// Receive up to buffer.len bytes. With a nonempty buffer, zero means EOF
    /// and closes the connection. An empty buffer is a no-op, not an EOF probe.
    pub fn receive(self: *TcpClient, buffer: []u8) !usize {
        if (!self.isConnected()) return error.NotConnected;
        if (buffer.len == 0) return 0;
        return self.receiveWithDeadline(buffer, self.options.read_timeout.toDeadline(self.io));
    }

    fn receiveWithDeadline(self: *TcpClient, buffer: []u8, deadline: std.Io.Timeout) !usize {
        const connection = self.connection orelse return error.NotConnected;
        errdefer self.disconnect();
        var buffers = [_][]u8{buffer};
        const result = try (try self.operateWithDeadline(.{ .net_read = .{
            .socket_handle = connection.socket.handle,
            .data = &buffers,
        } }, deadline)).net_read;
        const count = result.data_len;
        if (count == 0) self.disconnect();
        return count;
    }

    /// Fill the buffer within one read timeout, or return EndOfStream/Timeout.
    /// On failure, the buffer may contain a partially received prefix.
    pub fn receiveExact(self: *TcpClient, buffer: []u8) !void {
        if (!self.isConnected()) return error.NotConnected;
        if (buffer.len == 0) return;
        const deadline = self.options.read_timeout.toDeadline(self.io);
        var offset: usize = 0;
        while (offset < buffer.len) {
            const count = try self.receiveWithDeadline(buffer[offset..], deadline);
            if (count == 0) return error.EndOfStream;
            offset += count;
        }
    }

    fn checkDeadline(self: *const TcpClient, deadline: std.Io.Timeout) !void {
        switch (deadline) {
            .none => {},
            .deadline => |timestamp| {
                if (timestamp.durationFromNow(self.io).raw.nanoseconds <= 0) return error.Timeout;
            },
            .duration => unreachable, // Convert once at the public operation boundary.
        }
    }

    fn operateWithDeadline(self: *TcpClient, operation: std.Io.Operation, deadline: std.Io.Timeout) !std.Io.Operation.Result {
        try self.checkDeadline(deadline);
        if (deadline == .none) return self.io.operate(operation);

        // Threaded's batch API polls readiness, then performs blocking I/O.
        // A large write can block after poll reports writable, so race the
        // operation itself against the deadline. Cancel joins the worker before
        // returning, keeping the socket and borrowed buffers alive throughout.
        const Result = union(enum) {
            operation: std.Io.Cancelable!std.Io.Operation.Result,
            timer: std.Io.Cancelable!void,
        };
        var results: [2]Result = undefined;
        var select = std.Io.Select(Result).init(self.io, &results);
        defer while (select.cancel()) |_| {};
        try select.concurrent(.operation, std.Io.operate, .{ self.io, operation });
        try select.concurrent(.timer, std.Io.Timeout.sleep, .{ deadline, self.io });
        switch (try select.await()) {
            .operation => |result| return result,
            .timer => |result| {
                try result;
                return error.Timeout;
            },
        }
    }
};

test "connect timeout cancels a pending backend connect without native timeout options" {
    const SlowConnect = struct {
        fn connect(_: ?*anyopaque, _: *const std.Io.net.IpAddress, options: std.Io.net.IpAddress.ConnectOptions) std.Io.net.IpAddress.ConnectError!std.Io.net.Socket {
            if (options.timeout != .none) return error.OptionUnsupported;
            try std.Io.sleep(std.testing.io, .fromSeconds(5), .awake);
            return error.ConnectionRefused;
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.netConnectIp = SlowConnect.connect;
    var io = std.testing.io;
    io.vtable = &vtable;
    var client = TcpClient.initWithOptions(io, .{
        .connect_timeout = .{ .duration = .{ .raw = .fromMilliseconds(25), .clock = .awake } },
    });
    defer client.disconnect();
    try std.testing.expectError(error.Timeout, client.connect("127.0.0.1", 5020));
    try std.testing.expect(!client.isConnected());
}

test "expired connect deadline leaves client disconnected" {
    var client = TcpClient.initWithOptions(std.testing.io, .{
        .connect_timeout = .{ .deadline = .{ .raw = .zero, .clock = .awake } },
    });
    defer client.disconnect();
    try std.testing.expectError(error.Timeout, client.connect("127.0.0.1", 5020));
    try std.testing.expect(!client.isConnected());
}
