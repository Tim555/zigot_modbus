//! Bounded deterministic mutation smoke test, not a coverage-guided fuzz campaign.
const std = @import("std");
const tcp = @import("zigot_modbus").tcp;

test "mutated TCP read/write frames return errors or bounded results without trapping" {
    var prng = std.Random.DefaultPrng.init(20261102);
    const random = prng.random();
    for (0..20000) |iteration| {
        var bytes: [300]u8 = undefined;
        random.bytes(&bytes);
        const length = random.uintLessThan(usize, bytes.len + 1);
        if (iteration % 2 == 0 and length >= 9) {
            // Preserve enough structure to reach validation beyond the MBAP IDs.
            try tcp.encode_mbap_header(0, 0, random.int(u16), 1, &bytes);
            const functions = [_]u8{ 1, 2, 3, 4, 5, 6, 15, 16 };
            bytes[7] = functions[(iteration / 2) % functions.len];
        }
        try exercise(bytes[0..length]);
    }
    // Near-overflow MBAP lengths must remain ordinary InvalidLength errors.
    for (65530..65536) |length| {
        var frame = [_]u8{ 0, 0, 0, 0, 0, 0, 1, 4, 2, 0, 1 };
        try tcp.encode_mbap_header(0, 0, @intCast(length), 1, &frame);
        try exercise(&frame);
    }
}

fn exercise(frame: []const u8) !void {
    var registers: [125]u16 = undefined;
    var bits: [2000]bool = undefined;
    const hr = tcp.decode_read_holding_registers_response(frame, 0, 1, &registers) catch 0;
    const ir = tcp.decode_read_input_registers_response(frame, 0, 1, &registers) catch 0;
    const co = tcp.decode_read_coils_response(frame, 0, 1, 10, &bits) catch 0;
    const di = tcp.decode_read_discrete_inputs_response(frame, 0, 1, 10, &bits) catch 0;
    _ = tcp.decode_write_single_coil_response(frame, 0, 1, 10, true) catch 0;
    _ = tcp.decode_write_single_register_response(frame, 0, 1, 10, 0xffff) catch 0;
    _ = tcp.decode_write_multiple_coils_response(frame, 0, 1, 10, 1968) catch 0;
    _ = tcp.decode_write_multiple_registers_response(frame, 0, 1, 10, 123) catch 0;
    _ = tcp.decode_exception_response(frame, 0, 1) catch null;
    try std.testing.expect(hr <= registers.len and ir <= registers.len);
    try std.testing.expect(co <= 10 and di <= 10);
}
