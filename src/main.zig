const std = @import("std");
const modbus = @import("zigot_modbus");

const usage =
    \\Usage: zigot_modbus_example [options] HOST
    \\Poll a Modbus TCP server (HOST must be an IPv4 or IPv6 literal).
    \\
    \\  -p, --port N       TCP port (default 502)
    \\  -a, --unit N       Unit ID, 0..255 (default 1)
    \\  -r, --start N      First reference (default 1; one-based)
    \\  -c, --count N      Consecutive values (default 1)
    \\  -t, --type N       0=coils, 1=discrete inputs, 3=input registers,
    \\                     4=holding registers (default 4)
    \\  -0                Use zero-based wire addresses
    \\  -l, --interval S   Delay between polls in seconds (default 1; >0)
    \\  -n, --polls N      Number of polls (default 0 = continuous)
    \\  -1                Poll once
    \\  -h, --help         Show this help
    \\
    \\Registers: maximum 125 per request; bits: maximum 2000.
    \\Stop continuous polling with Ctrl+C. Errors stop polling with exit code 1.
    \\
;

const Options = struct {
    host: ?[]const u8 = null,
    port: u16 = 502,
    unit: u8 = 1,
    start: u32 = 1,
    count: u16 = 1,
    table: u8 = 4,
    zero_based: bool = false,
    interval_ns: i64 = std.time.ns_per_s,
    polls: u64 = 0,
    help: bool = false,

    fn address(self: Options) u16 {
        return @intCast(self.start - @intFromBool(!self.zero_based));
    }
};

fn matches(arg: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, arg, short) or std.mem.eql(u8, arg, long);
}

fn number(comptime T: type, value: []const u8) !T {
    return std.fmt.parseInt(T, value, 10) catch error.InvalidNumber;
}

fn parse(args: []const []const u8) !Options {
    var o: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (matches(arg, "-h", "--help")) {
            o.help = true;
            return o;
        } else if (std.mem.eql(u8, arg, "-0")) {
            o.zero_based = true;
        } else if (std.mem.eql(u8, arg, "-1")) {
            o.polls = 1;
        } else if (arg.len > 0 and arg[0] == '-') {
            if (!matches(arg, "-p", "--port") and !matches(arg, "-a", "--unit") and
                !matches(arg, "-r", "--start") and !matches(arg, "-c", "--count") and
                !matches(arg, "-t", "--type") and !matches(arg, "-l", "--interval") and
                !matches(arg, "-n", "--polls")) return error.UnknownOption;
            i += 1;
            if (i == args.len) return error.MissingOptionValue;
            const value = args[i];
            if (matches(arg, "-p", "--port")) o.port = try number(u16, value) else if (matches(arg, "-a", "--unit")) o.unit = try number(u8, value) else if (matches(arg, "-r", "--start")) o.start = try number(u32, value) else if (matches(arg, "-c", "--count")) o.count = try number(u16, value) else if (matches(arg, "-t", "--type")) o.table = try number(u8, value) else if (matches(arg, "-n", "--polls")) o.polls = try number(u64, value) else {
                const seconds = std.fmt.parseFloat(f64, value) catch return error.InvalidInterval;
                if (!std.math.isFinite(seconds) or seconds < 0.000000001 or seconds > 86400) return error.InvalidInterval;
                o.interval_ns = @intFromFloat(seconds * std.time.ns_per_s);
            }
        } else {
            if (o.host != null) return error.MultipleHosts;
            o.host = arg;
        }
    }
    if (o.host == null) return error.MissingHost;
    if (o.port == 0) return error.InvalidPort;
    if (o.table > 4 or o.table == 2) return error.InvalidType;
    if (o.count == 0 or o.count > (if (o.table < 2) @as(u16, 2000) else @as(u16, 125))) return error.InvalidCount;
    if ((!o.zero_based and o.start == 0) or o.start > (if (o.zero_based) @as(u32, 65535) else @as(u32, 65536))) return error.InvalidAddress;
    if (@as(u32, o.address()) + o.count > 65536) return error.InvalidRange;
    return o;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const o = parse(args[1..]) catch |err| {
        std.debug.print("Argument error: {s}\n\n{s}", .{ @errorName(err), usage });
        std.process.exit(2);
    };
    if (o.help) {
        try std.Io.File.stdout().writeStreamingAll(init.io, usage);
        return;
    }
    run(init.io, o) catch |err| {
        std.debug.print("Polling failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(io: std.Io, o: Options) !void {
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    const out = &output.interface;
    const table = switch (o.table) {
        0 => "coils (FC01)",
        1 => "discrete inputs (FC02)",
        3 => "input registers (FC04)",
        else => "holding registers (FC03)",
    };
    try out.print("Modbus TCP [{s}]:{d} | unit {d} | {s}\nReferences {d}..{d} ({s}) | interval {d} ms | polls ", .{
        o.host.?,                                        o.port,                                       o.unit, table, o.start, o.start + o.count - 1,
        if (o.zero_based) "zero-based" else "one-based", @divTrunc(o.interval_ns, std.time.ns_per_ms),
    });
    if (o.polls == 0) try out.writeAll("continuous\n") else try out.print("{d}\n", .{o.polls});
    try out.flush();
    var client = modbus.SyncTcpModbusClient.init(io);
    defer client.disconnect();
    try client.connect(o.host.?, o.port);
    var registers: [125]u16 = undefined;
    var bits: [2000]bool = undefined;
    var poll: u64 = 0;
    while (o.polls == 0 or poll < o.polls) {
        poll += 1;
        const result = switch (o.table) {
            0 => try client.readCoilsDetailed(o.address(), o.count, o.unit, &bits),
            1 => try client.readDiscreteInputsDetailed(o.address(), o.count, o.unit, &bits),
            3 => try client.readInputRegisterDetailed(o.address(), o.count, o.unit, &registers),
            else => try client.readHoldingRegisterDetailed(o.address(), o.count, o.unit, &registers),
        };
        switch (result) {
            .exception => |exc| {
                std.debug.print("Poll {d}: Modbus exception 0x{x:0>2} (function 0x{x:0>2}, unit {d})\n", .{ poll, exc.exception_code, exc.function_code, exc.unit_id });
                return error.ModbusException;
            },
            .count => |count| {
                try out.print("\nPoll {d}\n Reference       Value       Hex\n", .{poll});
                for (0..count) |index| {
                    const value: u16 = if (o.table < 2) @intFromBool(bits[index]) else registers[index];
                    try out.print("[{d: >9}] {d: >10}    0x{x:0>4}\n", .{ o.start + index, value, value });
                }
                try out.flush();
            },
        }
        if (o.polls == 0 or poll < o.polls) try std.Io.sleep(io, .fromNanoseconds(o.interval_ns), .awake);
    }
}

test "parse polling options and address conventions" {
    const o = try parse(&.{ "-p", "5020", "-r", "11", "-c", "2", "-l", "0.25", "-n", "3", "127.0.0.1" });
    try std.testing.expectEqual(@as(u16, 10), o.address());
    try std.testing.expectEqual(@as(i64, 250000000), o.interval_ns);
    try std.testing.expectEqual(@as(u64, 3), o.polls);
    const zero = try parse(&.{ "::1", "-0", "-r", "65535", "-1" });
    try std.testing.expectEqual(@as(u16, 65535), zero.address());
    try std.testing.expectEqual(@as(u64, 1), zero.polls);
}

test "reject invalid or ambiguous requests before connecting" {
    try std.testing.expectError(error.MissingHost, parse(&.{}));
    try std.testing.expectError(error.MissingOptionValue, parse(&.{ "localhost", "-c" }));
    try std.testing.expectError(error.InvalidAddress, parse(&.{ "::1", "-r", "0" }));
    try std.testing.expectError(error.InvalidRange, parse(&.{ "::1", "-r", "65536", "-c", "2" }));
    try std.testing.expectError(error.InvalidCount, parse(&.{ "::1", "-c", "126" }));
    try std.testing.expectError(error.InvalidType, parse(&.{ "::1", "-t", "2" }));
    try std.testing.expectError(error.InvalidInterval, parse(&.{ "::1", "-l", "nan" }));
    try std.testing.expectError(error.InvalidInterval, parse(&.{ "::1", "-l", "0" }));
    try std.testing.expectError(error.MultipleHosts, parse(&.{ "::1", "127.0.0.1" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "::1", "--typo" }));
    _ = try parse(&.{ "::1", "-t", "0", "-c", "2000" });
}
